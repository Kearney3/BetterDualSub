import XCTest
import Translation
@testable import BetterDualSubCore

@MainActor
private final class PipelineTarget: SubtitleTranslationTarget {
    var loadID = UUID()
    var replacements: [SubtitleDocument] = []
    func setSecondary(_ document: SubtitleDocument, name: String) { replacements.append(document) }
    var translationPositionMs = 0
    /// Later parts of the same translation replace the last one, so `replacements` holds one entry per translation.
    func updateSecondary(_ document: SubtitleDocument) { replacements[replacements.count - 1] = document }
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

/// A language model whose requests take a moment, so batches sent at the same time overlap, and which can fail one.
@MainActor
private final class SlowSessionStub: SubtitleTranslationSession {
    var understandsContext: Bool { true }
    var inFlight = 0, maxInFlight = 0, started = 0, completed = 0
    var translated: [Int] = []
    var failingFirstIndex: Int?

    func translate(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext,
                   receive: (SubtitleTranslationOutput) throws -> Void) async throws {
        started += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if let failingFirstIndex, inputs.first?.index == failingFirstIndex { throw SubtitleError.message("error.translation.incomplete") }
        try await Task.sleep(for: .milliseconds(60))
        for input in inputs {
            translated.append(input.index)
            try receive(SubtitleTranslationOutput(identifier: String(input.index), text: "T:" + input.text, segments: input.segments.map { "T:" + $0 }))
        }
        completed += 1
    }

    func extractTerms(_ lines: [String], known: [GlossaryEntry]) async throws -> [GlossaryEntry] { [] }
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

    func testNamesKeptInTheOriginalSetFoundEntriesAsideButKeepTheUsersOwn() async throws {
        let session = ContextSessionStub(), manager = PipelineTarget()
        session.terms = [GlossaryEntry(source: "Walter", target: "沃尔特", kind: .person),
                         GlossaryEntry(source: "Albuquerque", target: "阿尔伯克基", kind: .place)]
        session.reply = { _, context in "Walter " + context.glossary.map(\.target).sorted().joined(separator: " ") }
        var saved: [TranslationGlossary] = []
        let translator = translator(session) { saved.append($0) }
        var configuration = model
        configuration.translateNames = false
        var glossary = glossary()
        glossary.entries = [GlossaryEntry(source: "Skyler", target: "斯凯勒", kind: .person)]
        let options = SubtitleTranslationOptions(engine: .llm(configuration), glossary: glossary, extractTerms: true)
        _ = await translator.start(plan: try plan(["Walter and Skyler live in Albuquerque."]), source: source, target: target,
                                   manager: manager, options: options)
        await settle { !translator.isBusy }
        XCTAssertEqual(saved.last?.entries.map(\.source), ["Skyler", "Walter", "Albuquerque"], "Found names are kept for later runs.")
        XCTAssertEqual(Set(session.contexts.first?.glossary.map(\.source) ?? []), ["Skyler", "Albuquerque"])
        XCTAssertEqual(session.contexts.count, 1, "A name left in the original is not a glossary miss.")
    }

    func testSubtitlePunctuationAppliesToChineseAndJapaneseOnly() async throws {
        for (language, expected) in [("zh-Hans", "好 走吧"), ("ja", "好 走吧"), ("fr", "好，走吧。")] {
            let session = SentenceSessionStub(), manager = PipelineTarget()
            session.reply = { _ in "好，走吧。" }
            let translator = SubtitleTranslator(availability: { _, _ in .installed }, makeSession: { _, _, _ in session })
            let options = SubtitleTranslationOptions(subtitlePunctuation: true)
            _ = await translator.start(plan: try plan(["Fine, let's go."]), source: source, target: Locale.Language(identifier: language),
                                       manager: manager, options: options)
            await settle { !translator.isBusy }
            XCTAssertEqual(manager.replacements.first?.items.first?.text, expected, language)
        }
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

    // MARK: Parallel requests

    /// Like `settle`, for requests that take real time: polls for up to thirty seconds.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<3000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Translation event did not complete")
    }

    private func onlineModel(parallel: Int?) -> LLMConfiguration {
        var configuration = model
        configuration.baseURL = "https://api.example.com/v1"
        configuration.parallelRequests = parallel
        return configuration
    }

    private func numberedLines(_ count: Int) -> [String] { (0..<count).map { "Line \($0)." } }

    func testOnlineModelSendsBatchesInParallelUpToTheLimitAndTranslatesEachLineOnce() async throws {
        let session = SlowSessionStub(), manager = PipelineTarget()
        let translator = translator(session)
        let options = SubtitleTranslationOptions(engine: .llm(onlineModel(parallel: 3)), glossary: glossary(), subdivide: false)
        _ = await translator.start(plan: try plan(numberedLines(30)), source: source, target: target, manager: manager, options: options)
        await eventually { !translator.isBusy }
        guard case .finished(let lines, _) = translator.phase else { return XCTFail("Expected a finished translation, got \(translator.phase)") }
        XCTAssertEqual(lines, 30)
        XCTAssertEqual(session.started, 6)
        XCTAssertEqual(session.maxInFlight, 3)
        XCTAssertEqual(session.translated.sorted(), Array(0..<30), "every line exactly once")
        let document = try XCTUnwrap(manager.replacements.last)
        XCTAssertEqual(document.items.map(\.text), numberedLines(30).map { "T:" + $0 })
    }

    func testAModelOnThisMacStaysSequentialUnlessAskedOtherwise() async throws {
        for (parallel, expected) in [(nil, 1), (2, 2)] as [(Int?, Int)] {
            var configuration = model
            configuration.parallelRequests = parallel
            let session = SlowSessionStub(), manager = PipelineTarget()
            let translator = translator(session)
            let options = SubtitleTranslationOptions(engine: .llm(configuration), glossary: glossary(), subdivide: false)
            _ = await translator.start(plan: try plan(numberedLines(20)), source: source, target: target, manager: manager, options: options)
            await eventually { !translator.isBusy }
            XCTAssertEqual(session.maxInFlight, expected, "parallel requests \(String(describing: parallel))")
            XCTAssertEqual(session.translated.sorted(), Array(0..<20))
        }
    }

    func testAFailedBatchStopsTheOthersAndReportsTheError() async throws {
        let session = SlowSessionStub(), manager = PipelineTarget()
        session.failingFirstIndex = 5
        let translator = translator(session)
        let options = SubtitleTranslationOptions(engine: .llm(onlineModel(parallel: 3)), glossary: glossary(), subdivide: false)
        _ = await translator.start(plan: try plan(numberedLines(60)), source: source, target: target, manager: manager, options: options)
        await eventually { !translator.isBusy }
        guard case .failed(let message) = translator.phase else { return XCTFail("Expected a failure, got \(translator.phase)") }
        XCTAssertFalse(message.isEmpty)
        let started = session.started
        XCTAssertLessThanOrEqual(started, 3, "only the batches already out when it failed were started")
        XCTAssertEqual(session.completed, 0, "the requests still out are cancelled")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.started, started, "no batch is started after the failure")
        XCTAssertLessThan(session.translated.count, 60)
    }

    func testCancellingStopsEveryRequestInFlight() async throws {
        let session = SlowSessionStub(), manager = PipelineTarget()
        let translator = translator(session)
        let options = SubtitleTranslationOptions(engine: .llm(onlineModel(parallel: 3)), glossary: glossary(), subdivide: false)
        _ = await translator.start(plan: try plan(numberedLines(60)), source: source, target: target, manager: manager, options: options)
        await eventually { session.inFlight == 3 }
        translator.cancel()
        await eventually { !translator.isBusy && session.inFlight == 0 }
        XCTAssertEqual(session.completed, 0)
        XCTAssertEqual(session.started, 3)
        XCTAssertTrue(session.translated.isEmpty)
        XCTAssertEqual(translator.phase, .cancelled)
    }

    func testParallelRequestsAreAutomaticByWhereTheModelRunsAndBounded() throws {
        var configuration = LLMConfiguration()
        XCTAssertEqual(configuration.effectiveParallelRequests, 1, "a model on this Mac handles one request at a time")
        configuration.baseURL = "https://api.example.com/v1"
        XCTAssertEqual(configuration.effectiveParallelRequests, LLMConfiguration.automaticOnlineRequests)
        configuration.parallelRequests = 9
        XCTAssertEqual(configuration.effectiveParallelRequests, 4)
        configuration.parallelRequests = 0
        XCTAssertEqual(configuration.effectiveParallelRequests, 1)
        configuration.parallelRequests = 2
        let decoded = try JSONDecoder().decode(LLMConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.parallelRequests, 2)
        // A configuration saved before the setting existed is automatic.
        let old = try JSONDecoder().decode(LLMConfiguration.self, from: Data(#"{"model":"m","baseURL":"https://x.test/v1"}"#.utf8))
        XCTAssertNil(old.parallelRequests)
    }

}

@MainActor
final class SubtitleTranslatorAutomaticStartTests: XCTestCase {
    func testAutomaticStartIsTakenOnceAndOnlyForItsLoad() {
        let translator = SubtitleTranslator()
        let load = UUID()
        XCTAssertFalse(translator.takeAutomaticStart(loadID: load))
        translator.requestAutomaticStart(loadID: load)
        XCTAssertFalse(translator.takeAutomaticStart(loadID: UUID()), "Another load does not start it.")
        XCTAssertTrue(translator.takeAutomaticStart(loadID: load))
        XCTAssertFalse(translator.takeAutomaticStart(loadID: load), "It is taken once.")
    }
}
