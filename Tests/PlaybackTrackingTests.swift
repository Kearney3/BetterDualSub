import XCTest
@testable import BetterDualSubCore

final class PlaybackTrackingTests: XCTestCase {
    private let tv = "com.apple.TV"

    private func report(_ id: String? = "com.apple.TV", elapsed: Double? = 10, rate: Double? = 1, playing: Bool? = true,
                        stamp: Double? = nil, duration: Double? = nil) -> NowPlayingReport {
        NowPlayingReport(bundleID: id, appName: id == "com.apple.TV" ? "TV" : id, isPlaying: playing, playbackRate: rate,
                         elapsedMicros: elapsed.map { $0 * 1_000_000 }, timestampEpochMicros: stamp.map { $0 * 1_000_000 },
                         durationMicros: duration.map { $0 * 1_000_000 })
    }

    func testElapsedIsAdvancedByTheReportAge() {
        XCTAssertEqual(report(rate: 2, stamp: 100).elapsedSeconds(atEpoch: 103), 16)
        // Paused, stale or unstamped reports are taken as they are.
        XCTAssertEqual(report(playing: false, stamp: 100).elapsedSeconds(atEpoch: 103), 10)
        XCTAssertEqual(report(stamp: 100).elapsedSeconds(atEpoch: 100 + 7200), 10)
        XCTAssertEqual(report().elapsedSeconds(atEpoch: 103), 10)
        // A missing isPlaying falls back to the rate; a zero rate while playing counts as 1×.
        XCTAssertFalse(report(rate: 0, playing: nil).playing)
        XCTAssertEqual(report(rate: 0, playing: true, stamp: 100).elapsedSeconds(atEpoch: 102), 12)
    }

    func testFollowsTargetWithClockAndDuration() {
        var tracker = PlaybackTracker()
        XCTAssertTrue(tracker.receive(report(duration: 5400), target: tv, uptime: 50, epoch: 0))
        XCTAssertEqual(tracker.followedApp?.name, "TV")
        XCTAssertEqual(tracker.durationMs, 5_400_000)
        XCTAssertEqual(tracker.clock.position(at: 52), 12_000)
        XCTAssertEqual(tracker.clock.rate, 1)
    }

    func testSubtitlesRunAtThePlayersSpeed() {
        var tracker = PlaybackTracker()
        // At 2× two seconds of video, and of subtitles, pass in one second.
        XCTAssertTrue(tracker.receive(report(elapsed: 100, rate: 2), target: tv, uptime: 0, epoch: 0))
        XCTAssertEqual(tracker.clock.position(at: 1), 102_000)
        XCTAssertEqual(tracker.playbackRate, 2)
        // Paused at 1.25×: the clock stops but the player's speed is still known.
        XCTAssertTrue(tracker.receive(report(elapsed: 103, rate: 1.25, playing: false), target: tv, uptime: 2, epoch: 0))
        XCTAssertEqual(tracker.clock.position(at: 5), 103_000)
        XCTAssertEqual(tracker.playbackRate, 1.25)
    }

    func testSmallDifferencesAreSmoothedAndLargeOnesAreSeeks() {
        var tracker = PlaybackTracker()
        _ = tracker.receive(report(elapsed: 10), target: tv, uptime: 0, epoch: 0)
        // 100 ms ahead of the extrapolated 11 s: jitter, halfway blend.
        _ = tracker.receive(report(elapsed: 11.1), target: tv, uptime: 1, epoch: 0)
        XCTAssertEqual(tracker.clock.position(at: 1), 11_050)
        // 2 s off: a seek, taken as reported.
        _ = tracker.receive(report(elapsed: 30), target: tv, uptime: 2, epoch: 0)
        XCTAssertEqual(tracker.clock.position(at: 2), 30_000)
        // A pause changes the rate, so it is never blended.
        _ = tracker.receive(report(elapsed: 30.05, playing: false), target: tv, uptime: 2, epoch: 0)
        XCTAssertEqual(tracker.clock.rate, 0)
        XCTAssertEqual(tracker.clock.position(at: 9), 30_050)
    }

    func testOtherPlayersAreIgnoredButRemembered() {
        var tracker = PlaybackTracker()
        XCTAssertFalse(tracker.receive(report("com.colliderli.iina"), target: tv, uptime: 0, epoch: 0))
        XCTAssertEqual(tracker.ignoredApp?.id, "com.colliderli.iina")
        // A paused other player is not offered.
        XCTAssertFalse(tracker.receive(report("com.colliderli.iina", playing: false), target: tv, uptime: 0, epoch: 0))
        XCTAssertNil(tracker.ignoredApp)
        // Nothing playing clears it, and any player is accepted when following every app.
        _ = tracker.receive(report("com.colliderli.iina"), target: tv, uptime: 0, epoch: 0)
        XCTAssertFalse(tracker.receive(nil, target: tv, uptime: 0, epoch: 0))
        XCTAssertNil(tracker.ignoredApp)
        XCTAssertTrue(tracker.receive(report("com.colliderli.iina"), target: PlaybackTracker.anyApp, uptime: 0, epoch: 0))
    }

    func testUnusablePositionsAreRejected() {
        var tracker = PlaybackTracker()
        XCTAssertFalse(tracker.receive(report(elapsed: nil), target: tv, uptime: 0, epoch: 0))
        XCTAssertFalse(tracker.receive(report(elapsed: -1), target: tv, uptime: 0, epoch: 0))
        XCTAssertFalse(tracker.receive(report(nil), target: tv, uptime: 0, epoch: 0))
        XCTAssertTrue(tracker.receive(report(rate: 99), target: tv, uptime: 0, epoch: 0))
        XCTAssertEqual(tracker.clock.rate, 0, "an implausible rate is treated as paused")
        tracker.invalidate()
        XCTAssertFalse(tracker.clock.valid)
        XCTAssertNil(tracker.followedApp)
    }

    func testStatusPrecedence() {
        let iina = SyncApp(id: "com.colliderli.iina", name: "IINA")
        XCTAssertEqual(SyncStatus.current(manualMode: true, listenerAlive: false, followedApp: "TV", playing: true, ignoredApp: nil), .manual)
        XCTAssertEqual(SyncStatus.current(manualMode: false, listenerAlive: false, followedApp: "TV", playing: true, ignoredApp: nil), .disconnected)
        XCTAssertEqual(SyncStatus.current(manualMode: false, listenerAlive: true, followedApp: "TV", playing: false, ignoredApp: iina),
                       .following(app: "TV", playing: false))
        XCTAssertEqual(SyncStatus.current(manualMode: false, listenerAlive: true, followedApp: nil, playing: false, ignoredApp: iina),
                       .waiting(otherApp: iina))
    }

    func testTimingStoreRoundTripAndLegacyFormat() throws {
        let suite = "BetterDualSubTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SubtitleTimingStore(defaults: defaults)

        XCTAssertTrue(store.load(title: "Movie").isDefault)
        let timing = SavedTiming(primaryOffsetMs: 1200, secondaryOffsetMs: 800)
        defaults.set([1.0427, 1], forKey: "speeds.Movie")
        // Old timeline speeds are ignored and dropped.
        XCTAssertTrue(store.load(title: "Movie").isDefault)
        store.save(timing, title: "Movie")
        XCTAssertEqual(store.load(title: "Movie"), timing)
        XCTAssertNil(defaults.object(forKey: "speeds.Movie"))

        store.save(SavedTiming(), title: "Movie")
        XCTAssertNil(defaults.object(forKey: "offsets.Movie"))
        XCTAssertNil(defaults.object(forKey: "speeds.Movie"))

        defaults.set([1000, 500], forKey: "offsets.Old")
        XCTAssertEqual(store.load(title: "Old"), SavedTiming(primaryOffsetMs: 1000, secondaryOffsetMs: 1500))
    }
}
