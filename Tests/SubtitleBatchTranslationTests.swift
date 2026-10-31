import XCTest
import Translation
@testable import BetterDualSubCore

/// A context-aware translator that records what each run is told, and can be made to fail one file.
@MainActor
private final class BatchSessionStub: SubtitleTranslationSession {
    var understandsContext: Bool { true }
    var glossaries: [[String]] = []
    var terms: [String: GlossaryEntry] = [:]
    var failing: Set<String> = []
    var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }

    func translate(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext,
                   receive: (SubtitleTranslationOutput) throws -> Void) async throws {
        glossaries.append(context.glossary.map(\.source))
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if inputs.contains(where: { failing.contains($0.text) }) { throw URLError(.networkConnectionLost) }
        for input in inputs {
            // Uses the glossary, so no line is asked for again.
            let segments = input.segments.map { segment in
                context.glossary.reduce("译" + segment) { $0.replacingOccurrences(of: $1.source, with: $1.target) }
            }
            try receive(SubtitleTranslationOutput(identifier: String(input.index), text: segments.joined(), segments: segments))
        }
    }

    func extractTerms(_ lines: [String], known: [GlossaryEntry]) async throws -> [GlossaryEntry] {
        lines.compactMap { line in terms.first { line.contains($0.key) }?.value }
    }

    func cancel() {}
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class SubtitleBatchTranslationTests: XCTestCase {
    private var folder: URL!
    private let source = Locale.Language(identifier: "en")
    private let target = Locale.Language(identifier: "zh-Hans")

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ lines: [String]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let srt = lines.enumerated().map { index, line in
            "\(index + 1)\n00:00:0\(index),000 --> 00:00:0\(index),900\n\(line)"
        }.joined(separator: "\n\n")
        try srt.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func batch(_ session: BatchSessionStub, saved: @escaping (TranslationGlossary) -> Void = { _ in }) -> SubtitleBatchTranslator {
        SubtitleBatchTranslator(translator: SubtitleTranslator(availability: { _, _ in .installed }, makeSession: { _, _, _ in session },
                                                               saveGlossary: { saved($0) }))
    }

    private func options(extract: Bool = false) -> SubtitleTranslationOptions {
        SubtitleTranslationOptions(glossary: TranslationGlossary(name: "Show", targetLanguage: "zh-Hans"), extractTerms: extract, subdivide: false)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<5000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Batch did not finish")
    }

    func testFilesRunInOrderAndShareTheGlossaryTheyGrow() async throws {
        let session = BatchSessionStub()
        session.terms = ["Walter": GlossaryEntry(source: "Walter", target: "沃尔特", kind: .person)]
        var saved: [TranslationGlossary] = []
        let batch = batch(session) { saved.append($0) }
        let first = try file("Show.S01E01.srt", ["Walter is here."]), second = try file("Show.S01E02.srt", ["Hi, Walter."])
        batch.setFiles([first, second])
        var outputs = SubtitleBatchTranslator.Outputs()
        outputs.bilingual = BilingualMergeOptions()
        batch.start(source: source, target: target, options: options(extract: true), outputs: outputs)
        await settle { !batch.isRunning }

        XCTAssertEqual(batch.items.map(\.status.isFinished), [true, true])
        // The name found in episode 1 is in the glossary sent with episode 2.
        XCTAssertEqual(session.glossaries, [["Walter"], ["Walter"]])
        XCTAssertEqual(batch.glossary?.entries.map(\.target), ["沃尔特"])
        XCTAssertEqual(saved.last?.name, "Show")
        let translated = folder.appendingPathComponent("Show.S01E02.zh-Hans.srt")
        XCTAssertEqual(try SubtitleDocument(text: String(contentsOf: translated, encoding: .utf8)).items.first?.text, "译Hi, 沃尔特.")
        let bilingual = folder.appendingPathComponent("Show.S01E01.bilingual.srt")
        XCTAssertEqual(try SubtitleDocument(text: String(contentsOf: bilingual, encoding: .utf8)).items.first?.text,
                       "Walter is here.\n译沃尔特 is here.")
    }

    func testAFailureMovesOnAndRetryRedoesOnlyIt() async throws {
        let session = BatchSessionStub()
        session.failing = ["Broken line."]
        let batch = batch(session)
        let urls = [try file("E1.srt", ["One."]), try file("E2.srt", ["Broken line."]), try file("E3.srt", ["Three."])]
        batch.setFiles(urls)
        batch.start(source: source, target: target, options: options(), outputs: .init())
        await settle { !batch.isRunning }
        XCTAssertEqual(batch.items.map(\.status.isFinished), [true, false, true])
        XCTAssertEqual(batch.failedCount, 1)

        session.failing = []
        session.glossaries = []
        batch.retryFailed(source: source, target: target, options: options(), outputs: .init())
        await settle { !batch.isRunning }
        XCTAssertEqual(session.glossaries.count, 1, "Only the failed file runs again.")
        XCTAssertEqual(batch.failedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("E2.zh-Hans.srt").path))
    }

    func testExistingOutputsAreSkippedAndSourcesNeverReplaced() async throws {
        let session = BatchSessionStub()
        let batch = batch(session)
        let done = try file("E1.srt", ["One."]), fresh = try file("E2.srt", ["Two."])
        try "kept".write(to: folder.appendingPathComponent("E1.zh-Hans.srt"), atomically: true, encoding: .utf8)
        batch.setFiles([done, fresh])
        batch.start(source: source, target: target, options: options(), outputs: .init())
        await settle { !batch.isRunning }
        XCTAssertEqual(batch.items.map(\.status), [.skipped, .done([folder.appendingPathComponent("E2.zh-Hans.srt")])])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("E1.zh-Hans.srt"), encoding: .utf8), "kept")

        // A pattern naming the output after the source itself writes beside it instead, even with overwrite.
        var outputs = SubtitleBatchTranslator.Outputs()
        outputs.translationPattern = "{name}"
        outputs.existing = .overwrite
        let planned = SubtitleBatchTranslator.destinations(for: done, language: "zh-Hans", outputs: outputs, sources: [done])
        XCTAssertEqual(planned.first?.destination?.lastPathComponent, "E1 2.srt")
    }

    func testCancelStopsTheRunAndLeavesTheRestToDo() async throws {
        let session = BatchSessionStub()
        session.blocked = true
        let batch = batch(session)
        batch.setFiles([try file("E1.srt", ["One."]), try file("E2.srt", ["Two."])])
        batch.start(source: source, target: target, options: options(), outputs: .init())
        await settle { session.waiting }
        batch.cancel()
        session.release()
        await settle { !batch.isRunning }
        XCTAssertEqual(batch.items.map(\.status), [.cancelled, .cancelled])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("E1.zh-Hans.srt").path))
    }
}
