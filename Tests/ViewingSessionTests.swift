import XCTest
@testable import BetterDualSubCore

final class ViewingSessionTests: XCTestCase {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)") }

    private func contents(of folder: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) })
    }

    func testUnchangedSnapshotsDoNotRewriteAnyFile() async throws {
        let url = folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ViewingSessionStore(url: url)
        let session = ViewingSession(primary: try document(), secondary: nil, title: "Movie", names: ["en"], sourceID: "file")
        _ = try await store.record(session)
        let files = [url.appendingPathComponent("index.json"), url.appendingPathComponent(session.id + ".json")]
        let before = try files.map { try FileManager.default.attributesOfItem(atPath: $0.path) }
        _ = try await store.record(session)
        let after = try files.map { try FileManager.default.attributesOfItem(atPath: $0.path) }
        for (old, new) in zip(before, after) {
            XCTAssertEqual(old[.systemFileNumber] as? NSNumber, new[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(old[.modificationDate] as? Date, new[.modificationDate] as? Date)
        }
    }

    func testRecordingOneSessionLeavesTheOthersFilesAlone() async throws {
        let url = folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ViewingSessionStore(url: url)
        let first = ViewingSession(primary: try document("One"), secondary: nil, title: "One", names: ["en"], sourceID: "a")
        var second = ViewingSession(primary: try document("Two"), secondary: nil, title: "Two", names: ["en"], sourceID: "b")
        _ = try await store.record(first)
        _ = try await store.record(second)
        let before = try contents(of: url)
        XCTAssertEqual(Set(before.keys), ["index.json", first.id + ".json", second.id + ".json"])
        second.timing.primaryOffsetMs = 900
        _ = try await store.record(second)
        let after = try contents(of: url)
        XCTAssertEqual(after[first.id + ".json"], before[first.id + ".json"])
        XCTAssertNotEqual(after[second.id + ".json"], before[second.id + ".json"])
        XCTAssertEqual(after["index.json"], before["index.json"], "the order did not change")
        // Reopening a session moves it to the front by rewriting only the index.
        _ = try await store.record(first)
        let moved = try contents(of: url)
        XCTAssertEqual(moved[first.id + ".json"], before[first.id + ".json"])
        XCTAssertNotEqual(moved["index.json"], before["index.json"])
        let reloaded = try await ViewingSessionStore(url: url).load()
        XCTAssertEqual(reloaded.map(\.title), ["One", "Two"])
    }

    func testHistoryBudgetEvictsOldestAndRejectsAnOversizedSessionWithoutChangingDisk() async throws {
        let url = folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ViewingSession(primary: try document(String(repeating: "A", count: 400)), secondary: nil,
                                   title: "First", names: ["en"], sourceID: "a")
        let second = ViewingSession(primary: try document(String(repeating: "B", count: 400)), secondary: nil,
                                title: "Second", names: ["en"], sourceID: "b")
        let size = try JSONEncoder().encode(first).count
        // A single record fits, but the pair does not.
        let store = ViewingSessionStore(url: url, maximumBytes: size + size / 2)
        _ = try await store.record(first)
        let retained = try await store.record(second)
        XCTAssertEqual(retained.map(\.title), ["Second"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent(first.id + ".json").path), "the evicted file is deleted")
        let previous = try contents(of: url)
        var oversized = second
        oversized.secondarySRT = String(repeating: "大", count: 1000)
        do { _ = try await store.record(oversized); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual(try contents(of: url), previous) }
        let restored = try await store.load()
        XCTAssertEqual(restored, [second])
    }

    func testDamagedHistoryIsReportedAndPreservedUntilExplicitClear() async throws {
        let url = folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ViewingSession(primary: try document(), secondary: nil, title: "Movie", names: ["en"], sourceID: "file")
        let store = ViewingSessionStore(url: url)
        _ = try await store.record(session)
        let index = url.appendingPathComponent("index.json")

        let future = Data("{\"version\":999,\"order\":[]}".utf8)
        try future.write(to: index, options: .atomic)
        do { _ = try await store.record(session); XCTFail("Expected unsupported version") }
        catch { XCTAssertEqual(try Data(contentsOf: index), future) }

        let broken = Data("broken".utf8)
        try broken.write(to: index, options: .atomic)
        do { _ = try await store.record(session); XCTFail("Expected damaged history") }
        catch { XCTAssertEqual(try Data(contentsOf: index), broken) }

        // A listed session whose file is gone, or an id that is not a hash (a path), is damage too.
        for order in [[session.id, String(repeating: "0", count: 64)], ["../../escape"]] {
            let data = Data("{\"version\":2,\"order\":[\(order.map { "\"\($0)\"" }.joined(separator: ","))]}".utf8)
            try data.write(to: index, options: .atomic)
            do { _ = try await ViewingSessionStore(url: url).load(); XCTFail("Expected damaged history for \(order)") }
            catch { XCTAssertEqual(try Data(contentsOf: index), data) }
        }

        let cleared = try await store.remove(id: nil)
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let empty = try await ViewingSessionStore(url: url).load()
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
        let video = URL(fileURLWithPath: "/tmp/Episode.MKV")
        XCTAssertEqual(SubtitleInput(urls: [video]), .package(video))
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
        let sample = try plan.document(translations: plan.sources.map { ["Translated \($0)"] })
        XCTAssertEqual(sample.items.count, 8)
        XCTAssertEqual(sample.items[7].startMs, document.items[7].startMs)
        XCTAssertEqual(sample.items[7].endMs, document.items[7].endMs)
        XCTAssertEqual(document.items.count, 30)
    }
}
