import XCTest
@testable import BetterDualSubCore

final class TranslationGlossaryTests: XCTestCase {
    private func glossary(_ pairs: [(String, String)]) -> TranslationGlossary {
        TranslationGlossary(name: "Show", targetLanguage: "zh-Hans-CN", entries: pairs.map { GlossaryEntry(source: $0.0, target: $0.1) })
    }

    func testMatchesWholeWordsIgnoringCaseLongestFirst() {
        let glossary = glossary([("New York", "纽约"), ("New York City", "纽约市"), ("Ann", "安"), ("霍格沃茨", "Hogwarts")])
        XCTAssertEqual(glossary.matches(in: "welcome to new york city, Anna.").map(\.source), ["New York City"])
        XCTAssertEqual(glossary.matches(in: "Ann's in New York.").map(\.source), ["New York", "Ann"])
        XCTAssertEqual(glossary.matches(in: "欢迎来到霍格沃茨魔法学校").map(\.source), ["霍格沃茨"])
    }

    func testSubstituteAndViolations() {
        let glossary = glossary([("Walter", "沃尔特"), ("Heisenberg", "海森堡")])
        XCTAssertEqual(glossary.substitute(in: "Walter, say my name: Heisenberg."), "沃尔特, say my name: 海森堡.")
        XCTAssertEqual(glossary.violations(source: "Walter, it's Heisenberg.", translation: "沃尔特，是海森伯格。").map(\.source), ["Heisenberg"])
        XCTAssertTrue(glossary.violations(source: "Nobody here.", translation: "这里没人。").isEmpty)
    }

    func testMergeKeepsTheUsersEntriesAndAddsNewOnes() {
        var glossary = glossary([("Jesse", "杰西")])
        let added = glossary.merge([GlossaryEntry(source: "jesse", target: "洁西"), GlossaryEntry(source: " Saul ", target: "索尔", kind: .person),
                                    GlossaryEntry(source: "Saul", target: "扫罗"), GlossaryEntry(source: "Empty", target: " ")])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(glossary.entries.map(\.target), ["杰西", "索尔"])
        XCTAssertEqual(glossary.entries.last?.automatic, true)
        XCTAssertEqual(glossary.entries.last?.kind, .person)
        XCTAssertEqual(glossary.entries.first?.automatic, false)
    }

    func testTSVRoundTripAndOtherGlossaryFormats() {
        let original = TranslationGlossary(name: "Show", targetLanguage: "zh-Hans-CN", entries: [
            GlossaryEntry(source: "Winterfell", target: "临冬城", kind: .place, note: "Stark seat"),
            GlossaryEntry(source: "Jon\tSnow", target: "琼恩·雪诺", kind: .person),
        ])
        let parsed = TranslationGlossary.entries(fromTSV: original.tsv)
        XCTAssertEqual(parsed.map(\.source), ["Winterfell", "Jon Snow"])
        XCTAssertEqual(parsed.map(\.target), ["临冬城", "琼恩·雪诺"])
        XCTAssertEqual(parsed.map(\.kind), [.place, .person])
        XCTAssertEqual(parsed.first?.note, "Stark seat")
        let other = TranslationGlossary.entries(fromTSV: "# names\nKing's Landing → 君临\nRed Keep = 红堡\n\nbroken line\n")
        XCTAssertEqual(other.map(\.source), ["King's Landing", "Red Keep"])
        XCTAssertEqual(other.map(\.target), ["君临", "红堡"])
    }

    func testSeriesNameDropsEpisodeAndReleaseDetails() {
        XCTAssertEqual(TranslationGlossary.seriesName(from: "Breaking.Bad.S01E02.1080p.WEB-DL"), "Breaking Bad")
        XCTAssertEqual(TranslationGlossary.seriesName(from: "The Office - S03E04 - The Coup"), "The Office")
        XCTAssertEqual(TranslationGlossary.seriesName(from: "Friends 2x05"), "Friends")
        XCTAssertEqual(TranslationGlossary.seriesName(from: "庆余年 第2集"), "庆余年")
        XCTAssertEqual(TranslationGlossary.seriesName(from: "Severance Season 2 Episode 1"), "Severance")
        XCTAssertEqual(TranslationGlossary.seriesName(from: "Inception"), "Inception")
    }

    func testStoreSavesLoadsAndListsByTargetLanguage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GlossaryStore(directory: directory)
        let empty = try await store.load(name: "Mr. Robot", targetLanguage: "zh-Hans-CN")
        XCTAssertTrue(empty.entries.isEmpty)
        var glossary = empty
        glossary.entries = [GlossaryEntry(source: "Elliot", target: "艾略特")]
        try await store.save(glossary)
        try await store.save(TranslationGlossary(name: "Mr. Robot", targetLanguage: "ja-Jpan-JP"))
        try await store.save(TranslationGlossary(name: "A/B: Test", targetLanguage: "zh-Hans-CN"))
        let loaded = try await store.load(name: "Mr. Robot", targetLanguage: "zh-Hans-CN")
        XCTAssertEqual(loaded, glossary)
        let names = await store.names(targetLanguage: "zh-Hans-CN")
        XCTAssertEqual(names, ["A/B: Test", "Mr. Robot"])
    }
}
