import XCTest
@testable import BetterDualSubCore

final class SubtitleMarkupTests: XCTestCase {
    func testEmphasisNestsAndClosesInAnyOrder() {
        XCTAssertEqual(SubtitleMarkup.runs("<i>Hello <b>big</i> world</b>"), [
            SubtitleTextRun(text: "Hello ", italic: true),
            SubtitleTextRun(text: "big", bold: true, italic: true),
            SubtitleTextRun(text: " world", bold: true),
        ])
        XCTAssertEqual(SubtitleMarkup.runs("<u>under</u><s>gone</s></b>plain"), [
            SubtitleTextRun(text: "under", underline: true),
            SubtitleTextRun(text: "gone", strikethrough: true),
            SubtitleTextRun(text: "plain"),
        ])
    }

    func testFontColorsAndWebVTTClasses() {
        XCTAssertEqual(SubtitleMarkup.runs(##"<font color="#ff0">Warn</font> <font color=red>Stop</font>"##), [
            SubtitleTextRun(text: "Warn", color: "#FFFF00"),
            SubtitleTextRun(text: " "),
            SubtitleTextRun(text: "Stop", color: "#FF0000"),
        ])
        XCTAssertEqual(SubtitleMarkup.runs("<c.yellow.bg_black>Hi</c> <v.loud Bob>there</v>"), [
            SubtitleTextRun(text: "Hi", color: "#FFFF00"),
            SubtitleTextRun(text: " there"),
        ])
    }

    func testASSOverridesLeftInSRT() {
        XCTAssertEqual(SubtitleMarkup.runs(#"{\an8}Top {\i1}line{\i0} {\c&H00FFFF&}gold{\r}"#), [
            SubtitleTextRun(text: "Top "),
            SubtitleTextRun(text: "line", italic: true),
            SubtitleTextRun(text: " "),
            SubtitleTextRun(text: "gold", color: "#FFFF00"),
        ])
    }

    func testEntitiesTimestampsRubyAndLiteralBrackets() {
        XCTAssertEqual(SubtitleMarkup.plainText("Tom &amp; Jerry&lrm; &#x4F60;&#22909; &bogus;"), "Tom & Jerry 你好 &bogus;")
        XCTAssertEqual(SubtitleMarkup.plainText("<00:00:01.000>Kara<00:00:01.500>oke"), "Karaoke")
        XCTAssertEqual(SubtitleMarkup.plainText("<ruby>漢<rt>kan</rt>字<rt>ji</rt></ruby>"), "漢字")
        XCTAssertEqual(SubtitleMarkup.plainText("a < b and c > d"), "a < b and c > d")
        XCTAssertEqual(SubtitleMarkup.plainText("2 <3"), "2 <3")
    }

    func testLineBreaksAreKeptAndBlankLinesTrimmed() {
        XCTAssertEqual(SubtitleMarkup.runs("  <i> First </i>\n\n<br/>Second  "), [
            SubtitleTextRun(text: "First", italic: true),
            SubtitleTextRun(text: "\nSecond"),
        ])
    }

    func testBalancedLinesIgnoreMarkupWidth() {
        let text = "<font color=\"#FFFFFF\">This sentence is long enough to need two balanced lines</font>"
        let split = SubtitleLineMode.double.apply(to: text)
        let lines = SubtitleMarkup.plainText(split).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertLessThan(abs(lines[0].count - lines[1].count), 12)
    }

    func testNextChangeFindsTheFollowingCueBoundary() throws {
        let document = try SubtitleDocument(items: [
            SubtitleItem(startMs: 1000, endMs: 2000, text: "A"),
            SubtitleItem(startMs: 1500, endMs: 3000, text: "B"),
            SubtitleItem(startMs: 5000, endMs: 6000, text: "C"),
        ])
        XCTAssertEqual(document.nextChange(after: 0), 1000)
        XCTAssertEqual(document.nextChange(after: 1000), 1500)
        XCTAssertEqual(document.nextChange(after: 1999), 2000)
        XCTAssertEqual(document.nextChange(after: 3000), 5000)
        XCTAssertNil(document.nextChange(after: 6000))
    }
}
