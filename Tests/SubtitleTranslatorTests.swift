import XCTest
import Translation
@testable import BetterDualSubCore

@MainActor
private final class TranslationTarget: SubtitleTranslationTarget {
    var loadID = UUID()
    var replacements: [SubtitleDocument] = []
    func setSecondary(_ document: SubtitleDocument, name: String) { replacements.append(document) }
}

@MainActor
private final class TranslationSessionStub: SubtitleTranslationSession {
    var blocked = false
    var cancelled = false
    var finished = false
    var batches: [[SubtitleTranslationInput]] = []
    var outputs: ([SubtitleTranslationInput]) -> [SubtitleTranslationOutput] = {
        $0.reversed().map { SubtitleTranslationOutput(identifier: String($0.index), text: "Translated \($0.index)") }
    }
    var failure: Error?
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }

    func translate(_ inputs: [SubtitleTranslationInput], receive: (SubtitleTranslationOutput) throws -> Void) async throws {
        batches.append(inputs)
        defer { finished = true }
        if blocked { await withCheckedContinuation { continuation = $0 } }
        // Deliberately deliver late responses even after cancel, as an uncooperative backend might.
        for response in outputs(inputs) { try receive(response) }
        if let failure { throw failure }
    }
    func cancel() { cancelled = true }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class SubtitleTranslatorTests: XCTestCase {
    private let source = Locale.Language(identifier: "en")
    private let targetLanguage = Locale.Language(identifier: "zh-Hans")

    private func plan(_ count: Int = 3) throws -> SubtitleTranslationPlan {
        SubtitleTranslationPlan(document: try SubtitleDocument(items: (0..<count).map {
            SubtitleItem(startMs: $0 * 2000, endMs: $0 * 2000 + 1000, text: "Line \($0)")
        }))
    }

    private func translator(_ session: TranslationSessionStub) -> SubtitleTranslator {
        SubtitleTranslator(availability: { _, _ in .installed }, makeSession: { _, _ in session })
    }

    func testOutOfOrderStreamingAcrossBatchesPreservesAllCueTiming() async throws {
        let session = TranslationSessionStub(), target = TranslationTarget()
        let translator = translator(session)
        let configuration = await translator.start(plan: try plan(85), source: source, target: targetLanguage, manager: target)
        XCTAssertNil(configuration)
        await settle { !translator.isBusy }
        XCTAssertEqual(session.batches.map(\.count), [40, 40, 5])
        let document = try XCTUnwrap(target.replacements.first)
        XCTAssertEqual(target.replacements.count, 1)
        XCTAssertEqual(document.items.map(\.text), (0..<85).map { "Translated \($0)" })
        XCTAssertEqual(document.items.map(\.startMs), (0..<85).map { $0 * 2000 })
        XCTAssertEqual(document.items.map(\.endMs), (0..<85).map { $0 * 2000 + 1000 })
        XCTAssertEqual(translator.result?.document.items, document.items)
        XCTAssertTrue(session.cancelled, "Completed sessions release their native work.")
    }

    func testPreviewProducesAResultWithoutReplacingTrackTwo() async throws {
        let session = TranslationSessionStub(), target = TranslationTarget()
        let translator = translator(session)
        _ = await translator.start(plan: try plan(20).preview(), source: source, target: targetLanguage, manager: target, preview: true)
        await settle { !translator.isBusy }
        XCTAssertTrue(translator.previewOnly)
        XCTAssertEqual(translator.result?.document.items.count, 8)
        XCTAssertTrue(target.replacements.isEmpty)
    }

    func testCancelStopsTheSessionImmediatelyAndLateWorkCannotOverwriteARetry() async throws {
        let old = TranslationSessionStub(), fresh = TranslationSessionStub(), target = TranslationTarget()
        old.blocked = true
        fresh.blocked = true
        var created = 0
        let translator = SubtitleTranslator(availability: { _, _ in .installed }, makeSession: { _, _ in
            created += 1
            return created == 1 ? old : fresh
        })
        defer { old.release(); fresh.release(); translator.cancel() }
        _ = await translator.start(plan: try plan(), source: source, target: targetLanguage, manager: target)
        await settle { old.waiting }
        translator.cancel()
        XCTAssertTrue(old.cancelled)
        XCTAssertEqual(translator.phase, .cancelled)
        _ = await translator.start(plan: try plan(), source: source, target: targetLanguage, manager: target)
        await settle { fresh.waiting }
        old.release()
        await settle { old.finished }
        XCTAssertEqual(translator.phase, .translating(done: 0, total: 3))
        XCTAssertTrue(target.replacements.isEmpty)
        fresh.release()
        await settle { !translator.isBusy }
        XCTAssertEqual(created, 2)
        XCTAssertEqual(target.replacements.count, 1)
    }

    func testChangingSubtitlesDuringAStreamRejectsTheOldTranslation() async throws {
        let session = TranslationSessionStub(), target = TranslationTarget()
        session.blocked = true
        let translator = translator(session)
        defer { session.release(); translator.cancel() }
        _ = await translator.start(plan: try plan(), source: source, target: targetLanguage, manager: target)
        await settle { session.waiting }
        target.loadID = UUID()
        session.release()
        await settle { !translator.isBusy }
        XCTAssertEqual(translator.phase, .cancelled)
        XCTAssertTrue(target.replacements.isEmpty)
        XCTAssertNil(translator.result)
        XCTAssertTrue(session.cancelled)
    }

    func testIncompleteDuplicateEmptyAndInvalidStreamResponsesNeverReplaceATrack() async throws {
        let cases: [[SubtitleTranslationOutput]] = [
            [.init(identifier: "0", text: "Only one")],
            [.init(identifier: "0", text: "One"), .init(identifier: "0", text: "Duplicate")],
            [.init(identifier: "0", text: "   ")],
            [.init(identifier: "99", text: "Wrong batch")],
            [.init(identifier: nil, text: "Missing identifier")]
        ]
        for responses in cases {
            let session = TranslationSessionStub(), target = TranslationTarget()
            session.outputs = { _ in responses }
            let translator = translator(session)
            _ = await translator.start(plan: try plan(), source: source, target: targetLanguage, manager: target)
            await settle { !translator.isBusy }
            guard case .failed = translator.phase else { return XCTFail("Expected a failed stream") }
            XCTAssertTrue(target.replacements.isEmpty)
            XCTAssertNil(translator.result)
            XCTAssertTrue(session.cancelled)
        }
    }

    func testStreamErrorDoesNotApplyPartialResults() async throws {
        let session = TranslationSessionStub(), target = TranslationTarget()
        session.outputs = { [.init(identifier: String($0[0].index), text: "Partial")] }
        session.failure = URLError(.networkConnectionLost)
        let translator = translator(session)
        _ = await translator.start(plan: try plan(), source: source, target: targetLanguage, manager: target)
        await settle { !translator.isBusy }
        guard case .failed = translator.phase else { return XCTFail("Expected the stream failure") }
        XCTAssertTrue(target.replacements.isEmpty)
        XCTAssertNil(translator.result)
    }

    func testOldLanguageDownloadCannotCompleteANewRequestForTheSamePair() async throws {
        let session = TranslationSessionStub(), target = TranslationTarget()
        var installed = false, created = 0
        let translator = SubtitleTranslator(availability: { _, _ in installed ? .installed : .supported }, makeSession: { _, _ in
            created += 1
            return session
        })
        let first = await translator.start(plan: try plan(), source: source, target: targetLanguage, manager: target)
        XCTAssertNotNil(first)
        let oldID = try XCTUnwrap(translator.pendingID)
        translator.cancel()
        let second = await translator.start(plan: try plan(), source: source, target: targetLanguage, manager: target)
        XCTAssertNotNil(second)
        let newID = try XCTUnwrap(translator.pendingID)
        XCTAssertNotEqual(oldID, newID)
        installed = true
        await translator.downloadFinished(error: nil, requestID: oldID, manager: target)
        XCTAssertEqual(translator.pendingID, newID)
        XCTAssertEqual(created, 0)
        await translator.downloadFinished(error: nil, requestID: newID, manager: target)
        await settle { !translator.isBusy }
        XCTAssertEqual(created, 1)
        XCTAssertEqual(target.replacements.count, 1)
    }

    func testCancelledAvailabilityCheckCannotRestoreAnOldPendingRequest() async throws {
        var waiting: CheckedContinuation<LanguageAvailability.Status, Never>?
        var checks = 0
        let session = TranslationSessionStub(), target = TranslationTarget()
        let translator = SubtitleTranslator(availability: { _, _ in
            checks += 1
            if checks == 1 { return await withCheckedContinuation { waiting = $0 } }
            return .installed
        }, makeSession: { _, _ in session })
        let prepared = try plan()
        let old = Task { await translator.start(plan: prepared, source: source, target: targetLanguage, manager: target) == nil }
        await settle { waiting != nil }
        translator.cancel()
        _ = await translator.start(plan: prepared, source: source, target: targetLanguage, manager: target)
        await settle { !translator.isBusy }
        waiting?.resume(returning: .supported)
        let oldRequestWasDiscarded = await old.value
        XCTAssertTrue(oldRequestWasDiscarded)
        XCTAssertNil(translator.pendingID)
        XCTAssertEqual(target.replacements.count, 1)
        guard case .finished = translator.phase else { return XCTFail("Expected the retry result") }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Translation event did not complete")
    }
}
