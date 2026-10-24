import XCTest
import Translation
@testable import BetterDualSubCore

@MainActor
private final class PipelineTarget: SubtitleTranslationTarget {
    var loadID = UUID()
    var replacements: [SubtitleDocument] = []
    func setSecondary(_ document: SubtitleDocument, name: String) { replacements.append(document) }
}

/// A translator that, like a language model, reads context and keeps each sentence's split over its cues.
@MainActor
private final class ContextSessionStub: SubtitleTranslationSession {
    var understandsContext: Bool { true }
    var batches: [[SubtitleTranslationInput]] = []
    var contexts: [SubtitleTranslationContext] = []
    var extracted: [[String]] = []
    var terms: [GlossaryEntry] = []
    var reply: (String, SubtitleTranslationContext) -> String = { segment, _ in "T:" + segment }

    func translate(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext,
                   receive: (SubtitleTranslationOutput) throws -> Void) async throws {
        batches.append(inputs)
        contexts.append(context)
        for input in inputs {
            let segments = input.segments.map { reply($0, context) }
            try receive(SubtitleTranslationOutput(identifier: String(input.index), text: segments.joined(), segments: segments))
        }
    }

    func extractTerms(_ lines: [String], known: [GlossaryEntry]) async throws -> [GlossaryEntry] {
        extracted.append(lines)
        return terms
    }

    func cancel() {}
}

/// A translator that sees whole sentences only, as the on-device one does.
@MainActor
private final class SentenceSessionStub: SubtitleTranslationSession {
    var inputs: [SubtitleTranslationInput] = []
    var reply: (String) -> String = { $0 }

    func translate(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext,
                   receive: (SubtitleTranslationOutput) throws -> Void) async throws {
        self.inputs += inputs
        for input in inputs { try receive(SubtitleTranslationOutput(identifier: String(input.index), text: reply(input.text))) }
    }

    func cancel() {}
}

@MainActor
final class SubtitleTranslationPipelineTests: XCTestCase {
    private let source = Locale.Language(identifier: "en")
    private let target = Locale.Language(identifier: "zh-Hans")

    private var model: LLMConfiguration {
        var configuration = LLMConfiguration()
        configuration.model = "test-model"
        configuration.batchSize = 5
        configuration.contextLines = 2
        return configuration
    }

    private func glossary(_ pairs: [(String, String)] = []) -> TranslationGlossary {
        TranslationGlossary(name: "Show", targetLanguage: "zh-Hans-CN", entries: pairs.map { GlossaryEntry(source: $0.0, target: $0.1) })
    }

    private func plan(_ lines: [String]) throws -> SubtitleTranslationPlan {
        SubtitleTranslationPlan(document: try SubtitleDocument(items: lines.enumerated().map {
            SubtitleItem(startMs: $0.offset * 1000, endMs: $0.offset * 1000 + 1000, text: $0.element)
        }))
    }

    private func translator(_ session: any SubtitleTranslationSession, saved: @escaping (TranslationGlossary) -> Void = { _ in }) -> SubtitleTranslator {
        SubtitleTranslator(availability: { _, _ in
            XCTFail("A language model needs no language download")
            return .installed
        }, makeSession: { _, _, _ in session }, saveGlossary: { saved($0) })
    }

    func testLanguageModelGetsEarlierTranslationsAndGlossaryAndKeepsSegments() async throws {
        let session = ContextSessionStub(), manager = PipelineTarget()
        session.reply = { segment, _ in segment.contains("Walter") ? "沃尔特说" : "T:" + segment }
        let translator = translator(session)
        let lines = ["Walter said", "hello."] + (2..<12).map { "Line \($0)." }
        let options = SubtitleTranslationOptions(engine: .llm(model), glossary: glossary([("Walter", "沃尔特")]), subdivide: false)
        _ = await translator.start(plan: try plan(lines), source: source, target: target, manager: manager, options: options)
        await settle { !translator.isBusy }
        XCTAssertEqual(session.batches.map(\.count), [5, 5, 1])
        XCTAssertEqual(session.batches[0][0].segments, ["Walter said", "hello."])
        XCTAssertEqual(session.contexts[0].glossary.map(\.source), ["Walter"])
        XCTAssertTrue(session.contexts[0].preceding.isEmpty)
        XCTAssertEqual(session.contexts[0].following, ["Line 6.", "Line 7.", "Line 8."])
        XCTAssertEqual(session.contexts[1].preceding.map(\.source), ["Line 4.", "Line 5."])
        XCTAssertEqual(session.contexts[1].preceding.map(\.translation), ["T:Line 4.", "T:Line 5."])
        XCTAssertTrue(session.contexts[1].glossary.isEmpty)
        let document = try XCTUnwrap(manager.replacements.first)
        XCTAssertEqual(Array(document.items.prefix(2)), [SubtitleItem(startMs: 0, endMs: 1000, text: "沃尔特说"),
                                                        SubtitleItem(startMs: 1000, endMs: 2000, text: "T:hello.")])
        XCTAssertEqual(document.items.count, 12)
        XCTAssertEqual(translator.unresolvedTerms, 0)
    }

    func testLinesIgnoringTheGlossaryAreAskedForOnceMoreStrictly() async throws {
        for fixes in [true, false] {
            let session = ContextSessionStub(), manager = PipelineTarget()
            session.reply = { segment, context in
                guard segment.contains("Walter") else { return "好。" }
                return context.strict && fixes ? "沃尔特在这。" : "华特在这。"
            }
            let translator = translator(session)
            let options = SubtitleTranslationOptions(engine: .llm(model), glossary: glossary([("Walter", "沃尔特")]))
            _ = await translator.start(plan: try plan(["Walter is here.", "Fine."]), source: source, target: target,
                                       manager: manager, options: options)
            await settle { !translator.isBusy }
            XCTAssertEqual(session.batches.map { $0.map(\.index) }, [[0, 1], [0]])
            XCTAssertEqual(session.contexts.map(\.strict), [false, true])
            XCTAssertEqual(manager.replacements.first?.items.first?.text, fixes ? "沃尔特在这。" : "华特在这。")
            XCTAssertEqual(translator.unresolvedTerms, fixes ? 0 : 1)
            guard case .finished = translator.phase else { return XCTFail("Expected a finished translation") }
        }
    }

    func testTermsAreFoundSavedAndUsedBeforeTranslating() async throws {
        let session = ContextSessionStub(), manager = PipelineTarget()
        session.terms = [GlossaryEntry(source: "Walter", target: "沃尔特", kind: .person)]
        var saved: [TranslationGlossary] = []
        let translator = translator(session) { saved.append($0) }
        var options = SubtitleTranslationOptions(engine: .llm(model), glossary: glossary(), extractTerms: true)
        _ = await translator.start(plan: try plan(["Walter is here.", "Fine."]), source: source, target: target,
                                   manager: manager, options: options)
        await settle { !translator.isBusy }
        XCTAssertEqual(session.extracted, [["Walter is here.", "Fine."]])
        XCTAssertEqual(saved.map { $0.entries.map(\.source) }, [["Walter"]])
        XCTAssertEqual(translator.glossary?.entries.first?.automatic, true)
        XCTAssertEqual(session.contexts.first?.glossary.map(\.target), ["沃尔特"])
        XCTAssertEqual(manager.replacements.count, 1)

        // Finding terms alone translates nothing; the terms already known are not added again.
        options.glossary = translator.glossary
        await translator.extractTerms(plan: try plan(["Walter is here."]), source: source, target: target, manager: manager, options: options)
        await settle { !translator.isBusy }
        XCTAssertEqual(translator.phase, .termsExtracted(added: 0))
        XCTAssertEqual(session.extracted.count, 2)
        XCTAssertEqual(manager.replacements.count, 1)
    }

    func testIncompleteLanguageModelSetupFailsBeforeAnyRequest() async throws {
        var created = 0
        let translator = SubtitleTranslator(availability: { _, _ in .installed }, makeSession: { _, _, _ in
            created += 1
            return ContextSessionStub()
        })
        _ = await translator.start(plan: try plan(["Hello."]), source: source, target: target, manager: PipelineTarget(),
                                   options: SubtitleTranslationOptions(engine: .llm(LLMConfiguration())))
        guard case .failed = translator.phase else { return XCTFail("Expected the setup error") }
        XCTAssertEqual(created, 0)
    }

    func testWholeSentenceTranslationsAreSharedOverTheirCuesAndGetGlossaryTerms() async throws {
        let session = SentenceSessionStub(), manager = PipelineTarget()
        session.reply = { $0.hasPrefix("I don't think") ? "我觉得我们不该去，太危险了。" : "好。" }
        let translator = SubtitleTranslator(availability: { _, _ in .installed }, makeSession: { _, _, _ in session })
        let options = SubtitleTranslationOptions(glossary: glossary([("Walter", "沃尔特")]))
        _ = await translator.start(plan: try plan(["I don't think we should go,", "it's too dangerous.", "Bye, Walter."]),
                                   source: source, target: target, manager: manager, options: options)
        await settle { !translator.isBusy }
        XCTAssertEqual(session.inputs.map(\.text), ["I don't think we should go, it's too dangerous.", "Bye, 沃尔特."])
        XCTAssertEqual(manager.replacements.first?.items, [
            SubtitleItem(startMs: 0, endMs: 1000, text: "我觉得我们不该去，"),
            SubtitleItem(startMs: 1000, endMs: 2000, text: "太危险了。"),
            SubtitleItem(startMs: 2000, endMs: 3000, text: "好。"),
        ])
        XCTAssertEqual(translator.unresolvedTerms, 1, "The on-device translator cannot be asked again.")
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Translation event did not complete")
    }
}
