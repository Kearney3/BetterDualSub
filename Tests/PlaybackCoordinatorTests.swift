import XCTest
@testable import BetterDualSubCore

@MainActor
private final class FakePlaybackClient: PlaybackClient {
    var onReport: ((NowPlayingReport?) -> Void)?
    var onDisconnect: (() -> Void)?
    var onDecodeFailure: (() -> Void)?
    var queries: [@MainActor (NowPlayingReport?) -> Void] = []
    var starts = 0
    var toggles = 0
    var seeks: [Double] = []
    func start() { starts += 1 }
    func stop() {}
    func requestReport(_ completion: @escaping @MainActor (NowPlayingReport?) -> Void) { queries.append(completion) }
    func togglePlayPause() { toggles += 1 }
    func seek(seconds: Double) { seeks.append(seconds) }
}

private actor PlaybackSleeper {
    private var waits: [UUID: (Duration, CheckedContinuation<Void, any Error>)] = [:]
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in waits[id] = (duration, continuation) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) { waits.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
    func finish(_ duration: Duration) -> Bool {
        guard let id = waits.first(where: { $0.value.0 == duration })?.key else { return false }
        waits.removeValue(forKey: id)?.1.resume()
        return true
    }
}

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    private var now: Double = 0

    private func report(_ id: String = "tv", elapsed: Double = 10, playing: Bool = true, rate: Double = 1) -> NowPlayingReport {
        NowPlayingReport(bundleID: id, appName: id, isPlaying: playing, playbackRate: rate,
                         elapsedMicros: elapsed * 1_000_000, durationMicros: 100_000_000)
    }

    private func coordinator(_ client: FakePlaybackClient, sleeper: PlaybackSleeper = PlaybackSleeper()) -> PlaybackCoordinator {
        PlaybackCoordinator(client: client, target: "tv", uptime: { self.now }, epoch: { 0 }, sleep: { try await sleeper.sleep($0) })
    }

    func testStartupRequiresListenerAcknowledgementAndNoMediaIsAnAcknowledgement() {
        let client = FakePlaybackClient()
        let acknowledged = coordinator(client)
        acknowledged.start()
        XCTAssertEqual(acknowledged.status, .connecting)
        client.onReport?(nil)
        XCTAssertEqual(acknowledged.status, .waiting(otherApp: nil))
        acknowledged.suspend()
    }

    func testHandshakeTimeoutRetriesAndRejectsOldListenerCallbacks() async {
        let client = FakePlaybackClient(), sleeper = PlaybackSleeper()
        let sync = coordinator(client, sleeper: sleeper)
        sync.start()
        let oldReport = client.onReport
        await finish(.seconds(5), in: sleeper)
        await settle { sync.connection == .disconnected }
        XCTAssertEqual(sync.status, .disconnected)
        oldReport?(report(elapsed: 99))
        XCTAssertEqual(sync.status, .disconnected)
        await finish(.seconds(2), in: sleeper)
        await settle { client.starts == 2 }
        XCTAssertEqual(sync.status, .connecting)
        client.onReport?(report())
        XCTAssertEqual(sync.status, .following(app: "tv", playing: true))
        oldReport?(report(elapsed: 99))
        XCTAssertEqual(sync.positionMs, 10_000)
        sync.suspend()
    }

    func testPlaybackPauseSeekAndNonTargetFallbackKeepTheCurrentPosition() {
        let client = FakePlaybackClient()
        let following = coordinator(client)
        following.start()
        client.onReport?(report(rate: 2))
        now = 3
        XCTAssertEqual(following.positionMs, 16_000)
        client.onReport?(report(elapsed: 16, playing: false, rate: 2))
        now = 8
        XCTAssertEqual(following.positionMs, 16_000)
        following.seek(toMs: 45_000, durationMs: 100_000)
        XCTAssertEqual(client.seeks, [45])
        client.onReport?(report("browser", elapsed: 99))
        XCTAssertEqual(following.positionMs, 45_000)
        XCTAssertEqual(following.status, .waiting(otherApp: SyncApp(id: "browser", name: "browser")))
        now = 20
        XCTAssertEqual(following.positionMs, 45_000)
        client.onReport?(nil)
        XCTAssertEqual(following.status, .waiting(otherApp: nil))
        following.togglePlay(durationMs: 100_000)
        now = 22
        XCTAssertEqual(following.positionMs, 47_000)
        following.suspend()
    }

    func testDisconnectFreezesTheFollowedClockAndCommandsUseManualFallback() {
        let client = FakePlaybackClient(), sync = coordinator(client)
        sync.start()
        client.onReport?(report())
        now = 5
        client.onDisconnect?()
        XCTAssertEqual(sync.positionMs, 15_000)
        XCTAssertFalse(sync.isPlaying)
        now = 10
        XCTAssertEqual(sync.positionMs, 15_000)
        sync.togglePlay(durationMs: 100_000)
        XCTAssertEqual(client.toggles, 0)
        now = 11
        XCTAssertEqual(sync.positionMs, 16_000)
        sync.suspend()
    }

    func testLateQueriesCannotOverrideNewReportsOrTargets() {
        let client = FakePlaybackClient(), sync = coordinator(client)
        sync.start()
        client.onReport?(report())
        sync.refresh()
        let stale = client.queries[0]
        client.onReport?(report(elapsed: 20))
        stale(report(elapsed: 1))
        XCTAssertEqual(sync.positionMs, 20_000)
        sync.setTarget("browser")
        let oldTarget = client.queries[1]
        sync.setTarget("tv")
        oldTarget(report("browser", elapsed: 99))
        XCTAssertEqual(sync.positionMs, 20_000)
        client.queries[2](report(elapsed: 30))
        XCTAssertEqual(sync.positionMs, 30_000)
        sync.suspend()
    }

    func testManualModeSpeedEndOfTimelineAndReturnToAutomatic() {
        let client = FakePlaybackClient(), sync = coordinator(client)
        sync.start()
        client.onReport?(report())
        now = 5
        sync.setMode(.manual)
        XCTAssertEqual(sync.positionMs, 15_000)
        XCTAssertEqual(sync.status, .manual)
        sync.setManualSpeed(2)
        sync.togglePlay(durationMs: 20_000)
        now = 9
        sync.tick(durationMs: 20_000)
        XCTAssertEqual(sync.positionMs, 20_000)
        XCTAssertFalse(sync.isPlaying)
        sync.setMode(.auto)
        XCTAssertEqual(sync.positionMs, 19_000)
        sync.togglePlay(durationMs: 100_000)
        XCTAssertEqual(client.toggles, 1)
        sync.suspend()
    }

    func testSleepRejectsOldEventsAndWakeWaitsForFreshListener() {
        let client = FakePlaybackClient(), sync = coordinator(client)
        sync.start()
        client.onReport?(report())
        let staleReport = client.onReport, staleDisconnect = client.onDisconnect
        now = 2
        sync.suspend()
        now = 500
        staleReport?(report(elapsed: 99))
        XCTAssertEqual(sync.positionMs, 12_000)
        sync.start()
        staleDisconnect?()
        XCTAssertEqual(sync.status, .connecting)
        client.onReport?(report(elapsed: 15))
        XCTAssertEqual(sync.positionMs, 15_000)
        sync.suspend()
    }

    func testRetryBackoffIsBoundedAndSilentPlaybackDoesNotExpire() {
        XCTAssertEqual((0...6).map(PlaybackCoordinator.retryDelay), [2, 4, 8, 16, 30, 30, 30])
        let client = FakePlaybackClient(), sync = coordinator(client)
        sync.start()
        client.onReport?(report())
        now = 3600
        XCTAssertTrue(sync.status.isFollowing, "The listener emits changes, not periodic heartbeats.")
        sync.suspend()
    }

    func testDecodeFailureRetriesAndSuccessfulRecoveryResetsBackoff() async {
        let client = FakePlaybackClient(), sleeper = PlaybackSleeper()
        let sync = coordinator(client, sleeper: sleeper)
        sync.start()
        client.onReport?(report())
        client.onDecodeFailure?()
        XCTAssertEqual(sync.status, .disconnected)
        await finish(.seconds(2), in: sleeper)
        await settle { client.starts == 2 }
        await finish(.seconds(5), in: sleeper)
        await settle { sync.connection == .disconnected }
        await finish(.seconds(4), in: sleeper)
        await settle { client.starts == 3 }
        client.onReport?(report(elapsed: 20))
        client.onDecodeFailure?()
        await finish(.seconds(2), in: sleeper)
        await settle { client.starts == 4 }
        sync.suspend()
    }

    func testSleepPausesTheManualClockAtItsCurrentPosition() {
        let client = FakePlaybackClient(), sync = coordinator(client)
        sync.setMode(.manual)
        sync.togglePlay(durationMs: 100_000)
        now = 3
        sync.suspend()
        now = 500
        XCTAssertEqual(sync.positionMs, 3000)
        XCTAssertFalse(sync.manualPlaying)
        sync.start()
        XCTAssertEqual(sync.positionMs, 3000)
        sync.suspend()
    }

    private func finish(_ duration: Duration, in sleeper: PlaybackSleeper) async {
        for _ in 0..<1000 {
            if await sleeper.finish(duration) { return }
            await Task.yield()
        }
        XCTFail("Expected a scheduled wait for \(duration)")
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Scheduled event did not complete")
    }
}
