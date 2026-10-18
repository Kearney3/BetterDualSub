import XCTest
@testable import BetterDualSubCore

final class ViewingSessionTests: XCTestCase {
    private func document(_ text: String = "Original", start: Int = 1000) throws -> SubtitleDocument {
        try SubtitleDocument(items: [SubtitleItem(startMs: start, endMs: start + 2000, text: text)])
    }

    func testIdentitySeparatesEditionsAndFilesButSurvivesRename() throws {
        let first = try document()
        let session = ViewingSession(primary: first, secondary: nil, title: "Movie", names: ["en"], sourceID: "file")
        let renamed = ViewingSession(primary: first, secondary: nil, title: "Renamed", names: ["new.srt"], sourceID: "file")
        XCTAssertEqual(session.id, renamed.id)
        XCTAssertNotEqual(session.id, ViewingSession(primary: first, secondary: nil, title: "Movie", names: ["en"], sourceID: "movie:other-edition").id)
        XCTAssertNotEqual(session.id, ViewingSession(primary: try document(start: 2000), secondary: nil, title: "Movie", names: ["en"], sourceID: "file").id)
        XCTAssertNotEqual(session.id, ViewingSession(primary: first, secondary: try document("第二轨"), title: "Movie", names: ["en", "zh"], sourceID: "file").id)
    }

    func testSessionRoundTripPreservesTranslationTimingAndReopensWithoutSourceFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let store = ViewingSessionStore(url: url)
        var session = ViewingSession(primary: try document(), secondary: nil, title: "Movie", names: ["en"], sourceID: "file")
        session.secondarySRT = try document("译文").srt
        session.names.append("Translated")
        session.linked = false
        session.timing = SavedTiming(primaryOffsetMs: 1200, secondaryOffsetMs: -500)
        _ = try await store.record(session)
        let reloadedStore = ViewingSessionStore(url: url)
        let reloaded = try await reloadedStore.load()
        let restored = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.timing, session.timing)
        XCTAssertFalse(restored.linked)
        XCTAssertEqual(try SubtitleDocument(text: restored.primarySRT).text(at: 1000), "Original")
        XCTAssertEqual(try SubtitleDocument(text: XCTUnwrap(restored.secondarySRT)).text(at: 1000), "译文")
    }

    func testHistoryUpdatesDeduplicatesBoundsAndRemovesOnlyRequestedSessions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ViewingSessionStore(url: folder.appendingPathComponent("history.json"))
        let first = try document()
        var newest: ViewingSession?
        for index in 0..<12 {
            let session = ViewingSession(primary: first, secondary: nil, title: "\(index)", names: ["en"], sourceID: "\(index)")
            _ = try await store.record(session)
            newest = session
        }
        var session = try XCTUnwrap(newest)
        session.timing.primaryOffsetMs = 2300
        let sessions = try await store.record(session)
        XCTAssertEqual(sessions.count, 10)
        XCTAssertEqual(sessions.first?.timing.primaryOffsetMs, 2300)
        XCTAssertFalse(sessions.contains { $0.title == "0" || $0.title == "1" })
        let remaining = try await store.remove(id: session.id)
        XCTAssertEqual(remaining.count, 9)
        XCTAssertFalse(remaining.contains { $0.id == session.id })
        let empty = try await store.remove(id: nil)
        XCTAssertTrue(empty.isEmpty)
    }

    func testCorruptedHistoryIsPreservedUntilExplicitClear() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let broken = Data("damaged history".utf8)
        try broken.write(to: url)
        let store = ViewingSessionStore(url: url)
        do {
            _ = try await store.record(ViewingSession(primary: document(), secondary: nil, title: "Movie", names: ["en"], sourceID: "file"))
            XCTFail("Must report damaged history")
        } catch { XCTAssertEqual(try Data(contentsOf: url), broken) }
        let cleared = try await store.remove(id: nil)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testDisplaySnapshotCannotRestoreUnrelatedPreferences() throws {
        let suite = "ViewingSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(40, forKey: "primaryFontSize")
        defaults.set("screen2", forKey: "subtitleDisplayID")
        defaults.set("private", forKey: "DSID")
        let snapshot = try XCTUnwrap(ViewingDisplaySettings.capture(defaults))
        defaults.set(70, forKey: "primaryFontSize")
        defaults.set("changed", forKey: "DSID")
        ViewingDisplaySettings.restore(snapshot, to: defaults)
        XCTAssertEqual(defaults.double(forKey: "primaryFontSize"), 40)
        XCTAssertEqual(defaults.string(forKey: "subtitleDisplayID"), "screen2")
        XCTAssertEqual(defaults.string(forKey: "DSID"), "changed")
        XCTAssertNil(defaults.object(forKey: "secondaryFontFamily"))
    }

    func testInputRoutingAndLanguagePreferences() throws {
        let movie = URL(string: "https://tv.apple.com/us/movie/example/umc.cmc.4a2ypxddplsdsahwxrc5fkz4x")!
        XCTAssertEqual(SubtitleInput(urls: [movie]), .movie(movie))
        let package = URL(fileURLWithPath: "/tmp/episode.movpkg")
        XCTAssertEqual(SubtitleInput(urls: [package]), .package(package))
        let files = [URL(fileURLWithPath: "/tmp/a.ass"), URL(fileURLWithPath: "/tmp/b.vtt")]
        XCTAssertEqual(SubtitleInput(urls: files), .files(files))
        XCTAssertEqual(SubtitleInput(urls: files + files), .unsupported)
        XCTAssertEqual(SubtitleInput(urls: [URL(string: "https://tv.apple.com/us/episode/example/umc.cmc.4a2ypxddplsdsahwxrc5fkz4x")!]), .unsupported)
        XCTAssertEqual(SubtitleInput(urls: [URL(string: "https://example.com/a.srt")!]), .unsupported)
        XCTAssertEqual(SubtitleInput(urls: []), .unsupported)
        XCTAssertTrue(SubtitleLanguagePreference.matches("en-US", "en"))
        XCTAssertTrue(SubtitleLanguagePreference.matches("en", "en-US"))
        XCTAssertTrue(SubtitleLanguagePreference.matches("cmn-Hans", "zh"))
        XCTAssertTrue(SubtitleLanguagePreference.matches("cmn-Hans", "zh-Hans"))
        XCTAssertFalse(SubtitleLanguagePreference.matches("en", ""))
        XCTAssertFalse(SubtitleLanguagePreference.matches("zh-Hant", "zh-Hans"))
    }

    func testTranslationPreviewKeepsTimingAndLimitsWork() throws {
        let document = try SubtitleDocument(items: (0..<30).map {
            SubtitleItem(startMs: $0 * 2000, endMs: $0 * 2000 + 1000, text: "Line \($0)")
        })
        let plan = try SubtitleTranslationPlan(document: document).preview()
        XCTAssertEqual(plan.sources.count, 8)
        let sample = try plan.document(translations: plan.sources.map { "Translated \($0)" })
        XCTAssertEqual(sample.items.count, 8)
        XCTAssertEqual(sample.items[7].startMs, document.items[7].startMs)
        XCTAssertEqual(sample.items[7].endMs, document.items[7].endMs)
        XCTAssertEqual(document.items.count, 30)
    }
}
