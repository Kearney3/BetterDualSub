import XCTest
@testable import BetterDualSubCore

final class SubtitleHealthTests: XCTestCase {
    private func document(_ spans: [(Int, Int)]) throws -> SubtitleDocument {
        try SubtitleDocument(items: spans.map { SubtitleItem(startMs: $0.0, endMs: $0.1, text: "x") })
    }

    private func key(_ primary: SubtitleDocument?, secondary: SubtitleDocument? = nil, timing: DualTrackTiming = DualTrackTiming(),
                     status: SyncStatus = .following(app: "TV", playing: true), text: Bool = false, at position: Int = 0) -> String {
        SubtitleHealth.key(primary: primary, secondary: secondary, timing: timing, status: status, isShowingText: text, positionMs: position)
    }

    func testStatesInOrderOfImportance() throws {
        let doc = try document([(10_000, 12_000), (30_000, 32_000)])
        XCTAssertEqual(key(nil), "health.noSubtitles")
        XCTAssertEqual(key(doc, status: .manual), "health.manual")
        XCTAssertEqual(key(doc, status: .waiting(otherApp: nil)), "health.noClock")
        XCTAssertEqual(key(doc, text: true, at: 11_000), "health.cue")
        XCTAssertEqual(key(doc, at: 20_000), "health.gap")
        XCTAssertEqual(key(doc, at: 5000), "health.outside")
        XCTAssertEqual(key(doc, at: 32_000), "health.outside")
    }

    func testDelaysAndDriftMoveTheCoveredSpan() throws {
        let doc = try document([(10_000, 12_000), (30_000, 32_000)])
        var timing = DualTrackTiming(linked: true)
        timing.setDelay(.primary, ms: 5000)
        XCTAssertEqual(key(doc, timing: timing, at: 5000), "health.outside")
        XCTAssertEqual(key(doc, timing: timing, at: 16_000), "health.gap")
        XCTAssertEqual(key(doc, timing: timing, at: 36_000), "health.gap")
        XCTAssertEqual(key(doc, timing: timing, at: 37_000), "health.outside")
    }

    func testTheSecondTrackWidensTheSpan() throws {
        let first = try document([(10_000, 12_000)]), second = try document([(2000, 4000), (20_000, 40_000)])
        XCTAssertEqual(key(first, secondary: second, at: 3000), "health.gap")
        XCTAssertEqual(key(first, secondary: second, at: 1000), "health.outside")
        XCTAssertEqual(key(first, secondary: second, at: 39_000), "health.gap")
    }

    func testDiagnosticEventsDropRepeatsAndKeepTheLatest() {
        var events = DiagnosticEvents()
        events.record("connecting")
        events.record("connecting")
        events.record("report")
        XCTAssertEqual(events.entries.map { $0["event"] }, ["connecting", "report"])
        XCTAssertNotNil(events.entries.first?["time"])
        for index in 0..<50 { events.record("e\(index)") }
        XCTAssertEqual(events.entries.count, DiagnosticEvents.limit)
        XCTAssertEqual(events.entries.last?["event"], "e49")
        XCTAssertEqual(events.entries.first?["event"], "e20")
    }
}
