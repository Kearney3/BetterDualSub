import XCTest
@testable import BetterDualSubCore

final class ViewingSessionTests: XCTestCase {
    func testUnchangedSnapshotsDoNotRewriteTheArchive() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ViewingSessionStore(url: url)
        let session = ViewingSession(primary: try document(), secondary: nil, title: "Movie", names: ["en"], sourceID: "file")
        _ = try await store.record(session)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        _ = try await store.record(session)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testLegacyHistoryUpgradesWithoutLosingSubtitleCopies() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var session = ViewingSession(primary: try document(), secondary: nil, title: "Movie", names: ["en"], sourceID: "file")
        try JSONEncoder().encode([session]).write(to: url)
        let store = ViewingSessionStore(url: url)
        let legacy = try await store.load()
        XCTAssertEqual(legacy, [session])
        session.timing.primaryOffsetMs = 1250
        _ = try await store.record(session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let restored = try await ViewingSessionStore(url: url).load()
        XCTAssertEqual(restored, [session])
    }

    func testHistoryBudgetEvictsOldestAndRejectsAnOversizedSessionWithoutChangingDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ViewingSession(primary: try document(String(repeating: "A", count: 400)), secondary: nil,
                                   title: "First", names: ["en"], sourceID: "a")
        let second = ViewingSession(primary: try document(String(repeating: "B", count: 400)), secondary: nil,
                                title: "Second", names: ["en"], sourceID: "b")
        // A single record fits, but the pair does not.
        let store = ViewingSessionStore(url: url, maximumBytes: 1100)
        _ = try await store.record(first)
        let retained = try await store.record(second)
        XCTAssertEqual(retained.map(\.title), ["Second"])
        let previous = try Data(contentsOf: url)
        var oversized = second
        oversized.secondarySRT = String(repeating: "大", count: 1000)
        do { _ = try await store.record(oversized); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual(try Data(contentsOf: url), previous) }
        let restored = try await store.load()
        XCTAssertEqual(restored, [second])
    }

    func testCachedHistoryNoticesExternalDamageAndPreservesUnknownVersions() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ViewingSession(primary: try document(), secondary: nil, title: "Movie", names: ["en"], sourceID: "file")
        let store = ViewingSessionStore(url: url)
        _ = try await store.record(session)
        let future = Data("{\"version\":999,\"sessions\":[]}".utf8)
        try future.write(to: url, options: .atomic)
        do { _ = try await store.record(session); XCTFail("Expected unsupported version") }
        catch { XCTAssertEqual(try Data(contentsOf: url), future) }
        let broken = Data("broken".utf8)
        try broken.write(to: url, options: .atomic)
        do { _ = try await store.record(session); XCTFail("Expected damaged history") }
        catch { XCTAssertEqual(try Data(contentsOf: url), broken) }
        let empty = try await store.remove(id: nil)
        XCTAssertTrue(empty.isEmpty)
    }

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
