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
        let translated = try plan.document(translations: [[" 你好 "], [""]])
        XCTAssertEqual(translated.items, [
            SubtitleItem(startMs: 1000, endMs: 2000, text: "你好"),
            SubtitleItem(startMs: 2500, endMs: 3000, text: "♪"),
            SubtitleItem(startMs: 3000, endMs: 4000, text: "你好"),
        ])
        XCTAssertThrowsError(try plan.document(translations: [["你好"]]))
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

    private func cues(_ lines: [(Int, Int, String)]) throws -> SubtitleDocument {
        try SubtitleDocument(items: lines.map { SubtitleItem(startMs: $0.0, endMs: $0.1, text: $0.2) })
    }

    func testSentenceSplitOverCuesIsOneUnitAndDialogueLinesStayApart() throws {
        let plan = SubtitleTranslationPlan(document: try cues([
            (0, 1000, "I don't think"), (1100, 2000, "we should go."),
            (3000, 4000, "- Why not?"), (4100, 5000, "- Because."), (6000, 7000, "[Man] Wait!"),
        ]))
        XCTAssertEqual(plan.units.map(\.segments), [["I don't think", "we should go."], ["- Why not?"], ["- Because."], ["[Man] Wait!"]])
        XCTAssertEqual(plan.sources.first, "I don't think we should go.")
    }

    func testGapsOverlapsAndLengthLimitsEndASentenceGroup() throws {
        let plan = SubtitleTranslationPlan(document: try cues([
            (0, 1000, "So I said"), (2500, 3000, "nothing at all."),
            (4000, 5000, "And she"), (4500, 5500, "left."),
            (6000, 6500, "one"), (6500, 7000, "two"), (7000, 7500, "three"), (7500, 8000, "four"), (8000, 8500, "five."),
            (9000, 9500, "Fine."),
        ]))
        XCTAssertEqual(plan.units.map(\.segments), [["So I said"], ["nothing at all."], ["And she"], ["left."],
                                                     ["one", "two", "three", "four"], ["five."], ["Fine."]])
    }

    func testAbbreviationsAndEllipsesDecideWhetherASentenceGoesOn() throws {
        let plan = SubtitleTranslationPlan(document: try cues([
            (0, 1000, "I met Mr."), (1000, 2000, "Smith today."),
            (3000, 4000, "I was thinking..."), (4000, 5000, "...maybe not."),
            (6000, 7000, "Wait..."), (7000, 8000, "Who's there?"),
        ]))
        XCTAssertEqual(plan.units.map(\.segments), [["I met Mr.", "Smith today."], ["I was thinking...", "...maybe not."],
                                                     ["Wait..."], ["Who's there?"]])
    }

    func testTracksWithoutPunctuationAreNotGrouped() throws {
        let plan = SubtitleTranslationPlan(document: try cues([(0, 1000, "你好"), (1000, 2000, "我们走吧"), (2000, 3000, "好的")]))
        XCTAssertEqual(plan.units.map(\.segments), [["你好"], ["我们走吧"], ["好的"]])
    }

    func testRebuildSharesASentenceOverItsCuesAndGivesEmptyPartsToANeighbour() throws {
        let plan = SubtitleTranslationPlan(document: try cues([
            (0, 1000, "I don't think"), (1100, 2000, "we should go."),
            (3000, 4000, "If you"), (4000, 5000, "really want to."),
            (6000, 7000, "I don't think"), (7100, 8000, "we should go."),
        ]))
        XCTAssertEqual(plan.units.count, 2, "A repeated sentence is translated once.")
        let document = try plan.document(translations: [["我觉得", "我们不该去。"], ["", "如果你真想去的话。"]])
        XCTAssertEqual(document.items, [
            SubtitleItem(startMs: 0, endMs: 1000, text: "我觉得"), SubtitleItem(startMs: 1100, endMs: 2000, text: "我们不该去。"),
            SubtitleItem(startMs: 3000, endMs: 5000, text: "如果你真想去的话。"),
            SubtitleItem(startMs: 6000, endMs: 7000, text: "我觉得"), SubtitleItem(startMs: 7100, endMs: 8000, text: "我们不该去。"),
        ])
        XCTAssertThrowsError(try plan.document(translations: [["我觉得"], ["如果你真想去的话。"]]), "Each segment needs a line.")
    }
}
