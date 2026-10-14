import XCTest
@testable import BetterDualSubCore

final class SubStationAlphaTests: XCTestCase {
    private let ass = """
    [Script Info]
    ScriptType: v4.00+

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour
    Style: Default,Arial,20,&H00FFFFFF

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\an8}Hello, {\\i1}world{\\i0}!\\N你好，世界！
    Comment: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,Disabled line
    Dialogue: 0,0:00:06.00,0:00:07.25,Default,,0,0,0,,Hard\\hspace and soft\\nbreak
    Dialogue: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}
    Dialogue: 0,1:02:03.04,1:02:04.00,Default,,0,0,0,,Late line
    """

    func testReadsDialogueTimingAndText() throws {
        XCTAssertTrue(SubtitleDocument.isSubStationAlpha(ass))
        let document = try SubtitleDocument(text: ass)
        XCTAssertEqual(document.items, [
            SubtitleItem(startMs: 1500, endMs: 3000, text: "Hello, world!\n你好，世界！"),
            SubtitleItem(startMs: 6000, endMs: 7250, text: "Hard space and soft break"),
            SubtitleItem(startMs: 3_723_040, endMs: 3_724_000, text: "Late line"),
        ])
    }

    func testReadsSSAWithItsOwnColumnsAndCRLF() throws {
        let ssa = "[Script Info]\r\nScriptType: v4.00\r\n\r\n[Events]\r\n"
            + "Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n"
            + "Dialogue: Marked=0,0:00:02.00,0:00:04.00,Default,NTP,0000,0000,0000,,First, with comma\r\n"
        let document = try SubtitleDocument(text: ssa)
        XCTAssertEqual(document.items, [SubtitleItem(startMs: 2000, endMs: 4000, text: "First, with comma")])
    }

    func testBilingualLinesOnSeparateDialoguesShowTogether() throws {
        let text = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,CN,,0,0,0,,你好
        Dialogue: 0,0:00:01.00,0:00:02.00,EN,,0,0,0,,Hello
        """
        XCTAssertEqual(try SubtitleDocument(text: text).text(at: 1500), "Hello\n你好")
    }

    func testSRTIsNotMistakenForSubStationAlpha() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n[Events] are coming\n"
        XCTAssertFalse(SubtitleDocument.isSubStationAlpha(srt))
        XCTAssertEqual(try SubtitleDocument(text: srt).items.first?.text, "[Events] are coming")
    }

    func testFileReaderDecodesLegacyEncodedASS() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-\(UUID().uuidString).ass")
        defer { try? FileManager.default.removeItem(at: url) }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        try XCTUnwrap(ass.data(using: gb18030)).write(to: url)
        XCTAssertEqual(try SubtitleFileReader.document(at: url).items.first?.text, "Hello, world!\n你好，世界！")
    }
}
