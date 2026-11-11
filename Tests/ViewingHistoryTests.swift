import XCTest
@testable import BetterDualSubCore

@MainActor
final class ViewingHistoryTests: XCTestCase {
    private func makeHistory(delay: Duration = .milliseconds(20)) -> (ViewingHistory, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        return (ViewingHistory(store: ViewingSessionStore(url: url), saveDelay: delay), url)
    }

    private func session(_ title: String) throws -> ViewingSession {
        ViewingSession(primary: try SubtitleDocument(items: [SubtitleItem(startMs: 0, endMs: 1000, text: title)]),
                       secondary: nil, title: title, names: ["en"], sourceID: title)
    }

    func testRecordsAndLoadsSessions() async throws {
        let (history, url) = makeHistory()
        defer { try? FileManager.default.removeItem(at: url) }
        history.record(try session("One"))
        history.record(try session("Two"))
        await history.flush(pending: nil)
        XCTAssertEqual(history.sessions.map(\.title), ["Two", "One"])
        XCTAssertNil(history.error)

        let reopened = ViewingHistory(store: ViewingSessionStore(url: url))
        await reopened.load()
        XCTAssertEqual(reopened.sessions.map(\.title), ["Two", "One"])
    }

    func testABurstOfScheduledSavesWritesTheLatestSnapshotOnce() async throws {
        let (history, url) = makeHistory(delay: .milliseconds(60))
        defer { try? FileManager.default.removeItem(at: url) }
        var latest = try session("Movie")
        var taken = 0
        for offset in 1...5 {
            latest.timing.primaryOffsetMs = offset * 100
            let snapshot = latest
            history.scheduleSave { taken += 1; return snapshot }
        }
        await history.flush(pending: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(taken, 0, "flush cancels the pending save instead of waiting for it")
        XCTAssertTrue(history.sessions.isEmpty)

        history.scheduleSave { taken += 1; return latest }
        try await Task.sleep(for: .milliseconds(200))
        await history.flush(pending: nil)
        XCTAssertEqual(taken, 1)
        XCTAssertEqual(history.sessions.first?.timing.primaryOffsetMs, 500)
    }

    func testFlushWritesThePendingSessionBeforeReturning() async throws {
        let (history, url) = makeHistory(delay: .seconds(30))
        defer { try? FileManager.default.removeItem(at: url) }
        history.scheduleSave { nil }
        await history.flush(pending: try session("Quit"))
        XCTAssertEqual(history.sessions.map(\.title), ["Quit"])
    }

    func testRemoveReportsWhichSessionsWentAndClearsThem() async throws {
        let (history, url) = makeHistory()
        defer { try? FileManager.default.removeItem(at: url) }
        let one = try session("One"), two = try session("Two")
        history.record(one)
        history.record(two)
        await history.flush(pending: nil)

        var removed: [String] = []
        history.remove(id: one.id) { removed += $0 }
        await history.flush(pending: nil)
        XCTAssertEqual(removed, [one.id])
        XCTAssertEqual(history.sessions.map(\.title), ["Two"])

        removed = []
        history.remove(id: nil) { removed += $0 }
        await history.flush(pending: nil)
        XCTAssertEqual(removed, [two.id])
        XCTAssertTrue(history.sessions.isEmpty)
    }

    func testDamagedHistoryIsReportedAndASuccessfulWriteClearsTheNotice() async throws {
        let (history, url) = makeHistory()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: url.appendingPathComponent("index.json"))
        await history.load()
        XCTAssertNotNil(history.error)
        history.record(try session("Blocked"))
        await history.flush(pending: nil)
        XCTAssertNotNil(history.error, "a damaged history is not overwritten")
        history.remove(id: nil)
        await history.flush(pending: nil)
        XCTAssertNil(history.error)
        history.record(try session("Fresh"))
        await history.flush(pending: nil)
        XCTAssertEqual(history.sessions.map(\.title), ["Fresh"])
    }

    func testDocumentsDecodeAndRejectMismatchedNames() async throws {
        var stored = try session("Hello")
        let (first, second) = try await ViewingHistory.documents(of: stored)
        XCTAssertEqual(first.text(at: 500), "Hello")
        XCTAssertNil(second)
        stored.names.append("extra")
        do { _ = try await ViewingHistory.documents(of: stored); XCTFail("Expected a mismatch") } catch {}
    }
}
