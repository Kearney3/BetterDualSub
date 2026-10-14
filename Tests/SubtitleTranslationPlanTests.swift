import XCTest
@testable import BetterDualSubCore

final class SubtitleTranslationPlanTests: XCTestCase {
    func testSourcesAreCleanedJoinedAndDeduplicated() throws {
        let document = try SubtitleDocument(items: [
            SubtitleItem(startMs: 1000, endMs: 2000, text: "<i>Where are</i>\nyou going?"),
            SubtitleItem(startMs: 3000, endMs: 4000, text: "{\\an8}Yeah."),
            SubtitleItem(startMs: 5000, endMs: 6000, text: "♪ ♪"),
            SubtitleItem(startMs: 7000, endMs: 8000, text: "Yeah."),
            SubtitleItem(startMs: 9000, endMs: 10000, text: "Tom &amp; Jerry"),
        ])
        let plan = SubtitleTranslationPlan(document: document)
        XCTAssertEqual(plan.sources, ["Where are you going?", "Yeah.", "Tom & Jerry"])
    }

    func testRebuildKeepsTimingAndUntranslatableCues() throws {
        let document = try SubtitleDocument(items: [
            SubtitleItem(startMs: 1000, endMs: 2000, text: "Hello"),
            SubtitleItem(startMs: 2500, endMs: 3000, text: "♪"),
            SubtitleItem(startMs: 3000, endMs: 4000, text: "Hello"),
            SubtitleItem(startMs: 5000, endMs: 6000, text: "Bye"),
        ])
        let plan = SubtitleTranslationPlan(document: document)
        let translated = try plan.document(translations: [" 你好 ", ""])
        XCTAssertEqual(translated.items, [
            SubtitleItem(startMs: 1000, endMs: 2000, text: "你好"),
            SubtitleItem(startMs: 2500, endMs: 3000, text: "♪"),
            SubtitleItem(startMs: 3000, endMs: 4000, text: "你好"),
        ])
        XCTAssertThrowsError(try plan.document(translations: ["你好"]))
    }

    func testCJKLinesJoinWithoutSpace() {
        XCTAssertEqual(SubtitleTranslationPlan.plainText("你要去\n哪里？"), "你要去哪里？")
    }

    func testDetectsTrackLanguage() throws {
        let document = try SubtitleDocument(items: [
            SubtitleItem(startMs: 0, endMs: 1000, text: "I don't think we should go there tonight."),
            SubtitleItem(startMs: 1000, endMs: 2000, text: "Why not? Everyone else is going to the party."),
        ])
        XCTAssertEqual(SubtitleTranslationPlan(document: document).dominantLanguage, "en")
    }
}
