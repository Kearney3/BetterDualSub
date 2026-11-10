import XCTest
@testable import BetterDualSubCore

final class SubtitleDriftTests: XCTestCase {
    func testFitsFrameRateDriftAndDelay() {
        // A 23.976 fps file played at 25 fps (scale 25 / 23.976), starting 2 s late.
        let scale = 25 / 23.976
        let point = { (file: Int) in SubtitleDrift.Point(fileMs: file, videoMs: Int((Double(file) * scale).rounded()) + 2000) }
        guard case .fitted(let fitted, let offset) = SubtitleDrift.fit(point(60_000), point(3_600_000)) else {
            return XCTFail("expected a fit")
        }
        XCTAssertEqual(fitted, scale, accuracy: 0.00001)
        XCTAssertEqual(offset, 2000, accuracy: 2)
        // Mapping back from video time lands on the file time of the line, and forward again on the video time.
        let later = point(1_800_000)
        XCTAssertEqual(SubtitleDrift.fileTime(atVideo: later.videoMs, offsetMs: offset, scale: fitted), 1_800_000, accuracy: 2)
        XCTAssertEqual(SubtitleDrift.videoTime(ofFile: 1_800_000, offsetMs: offset, scale: fitted), later.videoMs, accuracy: 2)
    }

    func testOrderOfThePointsDoesNotMatter() {
        let a = SubtitleDrift.Point(fileMs: 60_000, videoMs: 62_000), b = SubtitleDrift.Point(fileMs: 3_000_000, videoMs: 3_125_000)
        guard case .fitted(let forward, _) = SubtitleDrift.fit(a, b), case .fitted(let backward, _) = SubtitleDrift.fit(b, a) else {
            return XCTFail("expected fits")
        }
        XCTAssertEqual(forward, backward, accuracy: 0.0000001)
    }

    func testPlainDelayKeepsUnitScale() {
        let a = SubtitleDrift.Point(fileMs: 100_000, videoMs: 101_500)
        let b = SubtitleDrift.Point(fileMs: 1_000_000, videoMs: 1_001_520)
        XCTAssertEqual(SubtitleDrift.fit(a, b), .fitted(scale: 1, offsetMs: 1500))
    }

    func testRejectsCloseOrImplausiblePoints() {
        let a = SubtitleDrift.Point(fileMs: 100_000, videoMs: 100_000)
        XCTAssertEqual(SubtitleDrift.fit(a, .init(fileMs: 110_000, videoMs: 110_500)), .tooClose)
        guard case .implausible = SubtitleDrift.fit(a, .init(fileMs: 200_000, videoMs: 300_000)) else {
            return XCTFail("expected an implausible scale")
        }
    }

    func testOffsetKeepsScaleAndBadStoredScalesAreIgnored() {
        XCTAssertEqual(SubtitleDrift.offset(for: .init(fileMs: 10_000, videoMs: 12_000), scale: 1.05), 1500)
        XCTAssertEqual(SubtitleDrift.valid(1.0427), 1.0427)
        XCTAssertEqual(SubtitleDrift.valid(0), 1)
        XCTAssertEqual(SubtitleDrift.valid(.nan), 1)
    }

    func testSavedTimingKeepsDriftAndReadsOlderArchives() throws {
        let suite = "SubtitleDriftTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SubtitleTimingStore(defaults: defaults)
        let timing = SavedTiming(primaryOffsetMs: 1200, secondaryOffsetMs: 1200, primaryScale: 1.0427, secondaryScale: 1.0427)
        store.save(timing, title: "Movie")
        XCTAssertEqual(store.load(title: "Movie"), timing)
        // Drift without any delay is still saved, and resetting everything removes it.
        store.save(SavedTiming(primaryScale: 0.96), title: "Movie")
        XCTAssertEqual(store.load(title: "Movie"), SavedTiming(primaryScale: 0.96))
        store.save(SavedTiming(primaryScale: 0.96), title: "session.abc")
        XCTAssertEqual(store.load(sessionID: "abc", legacyTitle: "Movie"), SavedTiming(primaryScale: 0.96))
        store.save(SavedTiming(), title: "Movie")
        XCTAssertNil(defaults.object(forKey: "drift.Movie"))
        XCTAssertEqual(store.load(title: "Movie"), SavedTiming())
        // Sessions archived before drift correction have no scales.
        let old = try JSONDecoder().decode(SavedTiming.self, from: Data(#"{"primaryOffsetMs":300,"secondaryOffsetMs":-200}"#.utf8))
        XCTAssertEqual(old, SavedTiming(primaryOffsetMs: 300, secondaryOffsetMs: -200))
        XCTAssertEqual(try JSONDecoder().decode(SavedTiming.self, from: JSONEncoder().encode(timing)), timing)
    }
}
