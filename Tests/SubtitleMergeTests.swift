import XCTest
@testable import BetterDualSubCore

final class SubtitleMergeTests: XCTestCase {
    private func document(_ items: [(Int, Int, String)]) throws -> SubtitleDocument {
        try SubtitleDocument(items: items.map { SubtitleItem(startMs: $0.0, endMs: $0.1, text: $0.2) })
    }

    func testOffsetIsFoundDespiteJitterAndDenseCues() throws {
        // Irregular gaps, so no other shift lines up as many cues by chance.
        var start = 1000
        let starts = (0..<60).map { index -> Int in
            defer { start += 1500 + (index * 739) % 2100 }
            return start
        }
        let reference = try document(starts.map { ($0, $0 + 1200, "Line") })
        // Track 2 runs 2.35 s early, with up to ±60 ms of jitter.
        let shifted = try document(starts.enumerated().map { index, start in
            let value = start - 2350 + (index % 5 - 2) * 30
            return (max(0, value), max(0, value) + 1100, "行")
        })
        let offset = try XCTUnwrap(shifted.estimatedOffset(to: reference))
        XCTAssertEqual(Double(offset), 2350, accuracy: 40)
        XCTAssertNil(try document([(0, 1000, "a")]).estimatedOffset(to: reference))
    }

    func testCombinedSRTKeepsOrderOption() throws {
        let en = try document([(1000, 3000, "Hello")]), zh = try document([(1100, 3200, "你好")])
        var options = BilingualMergeOptions()
        options.secondaryOnTop = true
        let files = try SubtitleDocument.merged(primary: en, secondary: zh, options: options)
        XCTAssertEqual(files.map(\.role), [.bilingual])
        XCTAssertEqual(try SubtitleDocument(text: files[0].contents).items, [SubtitleItem(startMs: 1000, endMs: 3000, text: "你好\nHello")])
    }

    func testASSUsesTwoStylesInOneEventAndEscapesText() throws {
        let en = try document([(1000, 3500, "<i>Hi</i> {there}\nfriend")]), zh = try document([(1050, 3500, "你好")])
        var options = BilingualMergeOptions()
        options.format = .ass
        let ass = try XCTUnwrap(SubtitleDocument.merged(primary: en, secondary: zh, options: options).first?.contents)
        XCTAssertTrue(ass.contains("Style: Primary,Arial,64"))
        XCTAssertTrue(ass.contains("Style: Secondary,Arial,48"))
        XCTAssertTrue(ass.contains(#"Dialogue: 0,0:00:01.00,0:00:03.50,Primary,,0,0,0,,{\i1}Hi{\i0} (there)\Nfriend\N{\rSecondary}你好"#), ass)
        // The app's own reader takes the script back with both languages in the cue.
        XCTAssertEqual(try SubtitleDocument(text: ass).items.first?.text, "Hi (there)\nfriend\n你好")
    }

    func testSeparateLayoutWritesTrackTwoMovedAndSnapped() throws {
        let en = try document([(1000, 3000, "Hello"), (5000, 7000, "Bye")])
        let zh = try document([(0, 2300, "你好"), (4100, 6000, "再见")])
        var options = BilingualMergeOptions()
        options.layout = .separate
        options.secondaryOffsetMs = 1000
        let files = try SubtitleDocument.merged(primary: en, secondary: zh, options: options)
        XCTAssertEqual(files.map(\.role), [.primary, .secondary])
        XCTAssertEqual(try SubtitleDocument(text: files[1].contents).items, [
            SubtitleItem(startMs: 1000, endMs: 3000, text: "你好"),
            SubtitleItem(startMs: 5000, endMs: 7000, text: "再见")
        ])
    }

    func testEpisodeKeysAndPairing() {
        XCTAssertEqual(EpisodeKey.parse("Show.S01E02.1080p.x264.en.srt"), EpisodeKey(season: 1, episode: 2))
        XCTAssertEqual(EpisodeKey.parse("show 2x10.srt"), EpisodeKey(season: 2, episode: 10))
        XCTAssertEqual(EpisodeKey.parse("剧名 第3集.zh.srt"), EpisodeKey(episode: 3))
        XCTAssertEqual(EpisodeKey.parse("Show - EP07 [720p].ass"), EpisodeKey(episode: 7))
        XCTAssertEqual(EpisodeKey.parse("Show.04.H.265.srt"), EpisodeKey(episode: 4))
        XCTAssertNil(EpisodeKey.parse("Movie.srt"))

        let url = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }
        let result = EpisodeKey.pair(primary: [url("S01E02.en.srt"), url("S01E01.en.srt"), url("Extra.en.srt")],
                                     secondary: [url("第1集.zh.srt"), url("S01E02.zh.srt"), url("S01E05.zh.srt")])
        XCTAssertEqual(result.pairs.map(\.primary.lastPathComponent), ["S01E01.en.srt", "S01E02.en.srt"])
        XCTAssertEqual(result.pairs.map(\.secondary.lastPathComponent), ["第1集.zh.srt", "S01E02.zh.srt"])
        XCTAssertEqual(result.unmatchedPrimary.map(\.lastPathComponent), ["Extra.en.srt"])
        XCTAssertEqual(result.unmatchedSecondary.map(\.lastPathComponent), ["S01E05.zh.srt"])
    }

    func testNamingAndExistingFiles() {
        let source = URL(fileURLWithPath: "/tmp/Show.S01E03.en.srt")
        XCTAssertEqual(OutputNaming.fileName(pattern: "{name}.{lang}", source: source, language: "zh-Hans", format: .srt),
                       "Show.S01E03.en.zh-Hans.srt")
        XCTAssertEqual(OutputNaming.fileName(pattern: "Show {episode}/{lang}", source: source, format: .ass), "Show S01E03.ass")
        XCTAssertEqual(OutputNaming.fileName(pattern: "", source: source, format: .srt), "Show.S01E03.en.srt")

        let folder = URL(fileURLWithPath: "/tmp/out")
        let existing: Set<String> = ["/tmp/out/a.srt", "/tmp/out/a 2.srt"]
        let exists = { (url: URL) in existing.contains(url.path) }
        XCTAssertNil(OutputNaming.destination(fileName: "a.srt", in: folder, existing: .skip, fileExists: exists))
        XCTAssertEqual(OutputNaming.destination(fileName: "a.srt", in: folder, existing: .overwrite, fileExists: exists)?.path, "/tmp/out/a.srt")
        XCTAssertEqual(OutputNaming.destination(fileName: "a.srt", in: folder, existing: .rename, fileExists: exists)?.path, "/tmp/out/a 3.srt")
        XCTAssertEqual(OutputNaming.destination(fileName: "b.srt", in: folder, existing: .skip, fileExists: exists)?.path, "/tmp/out/b.srt")
        // The file being read is never replaced, even with overwrite.
        let source2 = URL(fileURLWithPath: "/tmp/out/b.srt")
        XCTAssertEqual(OutputNaming.destination(fileName: "b.srt", in: folder, existing: .overwrite, protected: [source2],
                                                fileExists: exists)?.path, "/tmp/out/b 2.srt")
    }

    func testScannerExpandsFoldersInEpisodeOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["E10.srt", "E2.vtt", "notes.txt", "nested/E1.srt"] {
            try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(SubtitleFileScanner.files(in: [folder]).map(\.lastPathComponent), ["E2.vtt", "E10.srt"])
        XCTAssertEqual(SubtitleFileScanner.files(in: [folder], recursive: true).map(\.lastPathComponent), ["E1.srt", "E2.vtt", "E10.srt"])
    }
}
