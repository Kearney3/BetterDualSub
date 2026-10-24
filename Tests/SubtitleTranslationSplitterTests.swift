import XCTest
@testable import BetterDualSubCore

final class SubtitleTranslationSplitterTests: XCTestCase {
    func testChineseSplitsAtPunctuationNearTheProportionalPoint() {
        XCTAssertEqual(SubtitleTranslationSplitter.split("我觉得我们不该去，太危险了。", weights: [10, 10]), ["我觉得我们不该去，", "太危险了。"])
    }

    func testSubtitlePunctuationDropsStopsAndCommasButKeepsOtherMarks() {
        let punctuate = { SubtitleTranslationSplitter.subtitlePunctuation($0, japanese: $1) }
        XCTAssertEqual(punctuate("我觉得，我们不该去。", false), "我觉得 我们不该去")
        XCTAssertEqual(punctuate("真的吗？太好了！", false), "真的吗？太好了！")
        XCTAssertEqual(punctuate("苹果、香蕉，还有……", false), "苹果、香蕉 还有……")
        XCTAssertEqual(punctuate("“好。”他说。", false), "“好”他说")
        XCTAssertEqual(punctuate("第一行，\n。\n第二行。", false), "第一行\n第二行", "Lines left empty are dropped.")
        XCTAssertEqual(punctuate("そうか、わかった。", true), "そうか わかった")
        XCTAssertEqual(punctuate("「行こう。」", true), "「行こう」")
    }

    func testLatinSplitsBetweenWordsInProportion() {
        let lines = SubtitleTranslationSplitter.split("Je ne pense pas que nous devrions y aller ce soir.", weights: [13, 13])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.joined(separator: " "), "Je ne pense pas que nous devrions y aller ce soir.")
        XCTAssertLessThan(abs(lines[0].count - lines[1].count), 12)
    }

    func testWordsAndContractionsAreNeverCut() {
        let words = Set("We don't know where they're going tonight".split(separator: " ").map(String.init))
        for weights in [[1, 1], [1, 3], [3, 1], [1, 1, 1]] {
            let lines = SubtitleTranslationSplitter.split("We don't know where they're going tonight", weights: weights)
            XCTAssertEqual(lines.count, weights.count)
            for word in lines.flatMap({ $0.split(separator: " ").map(String.init) }) {
                XCTAssertTrue(words.contains(word), "\(word) is part of a word, in \(lines)")
            }
        }
    }

    func testShortTranslationsLeaveTrailingLinesEmpty() {
        XCTAssertEqual(SubtitleTranslationSplitter.split("好", weights: [1, 1]), ["好", ""])
        XCTAssertEqual(SubtitleTranslationSplitter.split(" 好的 ", weights: [4]), ["好的"])
    }

    func testLongCuesAreSubdividedWithinTheirTime() throws {
        let long = "我们必须在天亮之前穿过那片森林到达河边的村庄，否则追兵就会赶上来，到时候谁也逃不掉了。"
        let document = try SubtitleDocument(items: [
            SubtitleItem(startMs: 1000, endMs: 7000, text: long),
            SubtitleItem(startMs: 8000, endMs: 9000, text: "好。"),
            SubtitleItem(startMs: 10000, endMs: 11500, text: long),
        ])
        let items = try SubtitleTranslationSplitter.subdivide(document).items
        let first = items.filter { $0.startMs >= 1000 && $0.endMs <= 7000 }
        XCTAssertGreaterThanOrEqual(first.count, 2)
        XCTAssertEqual(first.first?.startMs, 1000)
        XCTAssertEqual(first.last?.endMs, 7000)
        for (a, b) in zip(first, first.dropFirst()) { XCTAssertEqual(a.endMs, b.startMs) }
        XCTAssertTrue(first.allSatisfy { $0.endMs - $0.startMs >= 1200 })
        XCTAssertEqual(first.map(\.text).joined(), long)
        XCTAssertTrue(items.contains(SubtitleItem(startMs: 8000, endMs: 9000, text: "好。")))
        XCTAssertTrue(items.contains(SubtitleItem(startMs: 10000, endMs: 11500, text: long)), "Too short to split.")
    }
}
