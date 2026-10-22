import Foundation

nonisolated enum SyncMode: String, CaseIterable, Sendable { case auto, manual }
nonisolated enum SyncSource: Sendable { case tv, manual }
nonisolated enum PlaybackConnection: Sendable { case connecting, connected, disconnected }

/// Reports from the listener are acknowledgements; a one-shot query is only a position refresh.
@MainActor
protocol PlaybackClient: AnyObject {
    var onReport: ((NowPlayingReport?) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    var onDecodeFailure: (() -> Void)? { get set }
    func start()
    func stop()
    func requestReport(_ completion: @escaping @MainActor (NowPlayingReport?) -> Void)
    func togglePlayPause()
    func seek(seconds: Double)
}

/// Owns listener recovery and both clocks. UI and tests exercise the same event and control paths.
@MainActor
final class PlaybackCoordinator {
    private let client: any PlaybackClient
    private let uptime: () -> TimeInterval
    private let epoch: () -> TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    private var handshakeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = UUID()
    private var queryID = UUID()
    private var failures = 0
    private var suspended = false
    private var manualClock = SubtitleClock(positionMs: 0, uptime: 0, rate: 0, valid: true)

    var onChange: (() -> Void)?
    private(set) var connection = PlaybackConnection.disconnected
    private(set) var tracker = PlaybackTracker()
    private(set) var mode: SyncMode
    private(set) var target: String
    private(set) var manualSpeed = 1.0
    private(set) var manualPlaying = false
    private(set) var lastReportUptime: TimeInterval?
    private(set) var reportedApp: SyncApp?
    private(set) var event = "idle"

    init(client: any PlaybackClient, target: String, mode: SyncMode = .auto,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         epoch: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.target = target
        self.mode = mode
        self.uptime = uptime
        self.epoch = epoch
        self.sleep = sleep
    }

    var activeSource: SyncSource { mode == .auto && tracker.clock.valid ? .tv : .manual }
    var positionMs: Int { activeSource == .tv ? tracker.clock.position(at: uptime()) : manualClock.position(at: uptime()) }
    var isPlaying: Bool { activeSource == .tv ? tracker.clock.rate > 0 : manualPlaying }
    var playbackSpeed: Double { activeSource == .tv ? tracker.playbackRate : manualSpeed }
    var status: SyncStatus {
        if mode == .manual { return .manual }
        switch connection {
        case .connecting: return .connecting
        case .disconnected: return .disconnected
        case .connected:
            return SyncStatus.current(manualMode: false, listenerAlive: true,
                                      followedApp: activeSource == .tv ? tracker.followedApp?.name : nil,
                                      playing: tracker.clock.rate > 0, ignoredApp: tracker.ignoredApp)
        }
    }

    func start() {
        suspended = false
        handshakeTask?.cancel()
        retryTask?.cancel()
        generation = UUID()
        queryID = UUID()
        let token = generation
        // Replacing the adapter's listener invalidates callbacks queued by an older process.
        client.stop()
        invalidateClock()
        connection = .connecting
        client.onReport = { [weak self] report in
            guard let self, self.generation == token, !self.suspended else { return }
            self.handshakeTask?.cancel()
            self.retryTask?.cancel()
            self.failures = 0
            self.connection = .connected
            self.queryID = UUID()
            self.receive(report)
        }
        client.onDisconnect = { [weak self] in
            guard let self, self.generation == token, !self.suspended else { return }
            self.failed("listenerStopped")
        }
        client.onDecodeFailure = { [weak self] in
            guard let self, self.generation == token, !self.suspended else { return }
            self.failed("decodeFailed")
        }
        event = "connecting"
        handshakeTask = Task { [weak self, sleep] in
            do { try await sleep(.seconds(5)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token, self.connection == .connecting else { return }
            self.failed("handshakeTimeout")
        }
        onChange?()
        client.start()
    }

    func suspend() {
        suspended = true
        generation = UUID()
        queryID = UUID()
        handshakeTask?.cancel()
        retryTask?.cancel()
        client.stop()
        invalidateClock()
        manualClock.rebase(at: uptime())
        manualClock.rate = 0
        manualPlaying = false
        connection = .disconnected
        event = "suspended"
        onChange?()
    }

    private func failed(_ reason: String) {
        // A queued report from this generation must not bring a failed listener back to life.
        generation = UUID()
        queryID = UUID()
        handshakeTask?.cancel()
        retryTask?.cancel()
        client.stop()
        invalidateClock()
        connection = .disconnected
        event = reason
        let delay = Self.retryDelay(failures: failures)
        failures += 1
        let token = generation
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(.seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token, !self.suspended else { return }
            self.start()
        }
        onChange?()
    }

    static func retryDelay(failures: Int) -> Int { [2, 4, 8, 16, 30][min(4, max(0, failures))] }

    private func receive(_ report: NowPlayingReport?) {
        lastReportUptime = uptime()
        reportedApp = report?.elapsedMicros == nil ? nil : report?.app
        if tracker.receive(report, target: target, uptime: uptime(), epoch: epoch()) {
            event = "report"
        } else {
            event = report == nil ? "noMedia" : (tracker.ignoredApp == nil ? "missingPosition" : "otherPlayer")
            invalidateClock()
        }
        onChange?()
    }

    private func invalidateClock() {
        if activeSource == .tv {
            manualClock = SubtitleClock(positionMs: Double(positionMs), uptime: uptime(), rate: 0, valid: true)
            manualPlaying = false
        }
        tracker.invalidate()
    }

    func refresh() {
        guard connection == .connected else { return }
        queryID = UUID()
        let query = queryID, token = generation
        client.requestReport { [weak self] report in
            guard let self, self.generation == token, self.queryID == query, self.connection == .connected else { return }
            self.receive(report)
        }
    }

    func setTarget(_ target: String) {
        guard self.target != target else { return }
        invalidateClock()
        tracker.clearIgnoredApp()
        self.target = target
        queryID = UUID()
        onChange?()
        refresh()
    }

    func setMode(_ mode: SyncMode) {
        guard self.mode != mode else { return }
        if activeSource == .tv, mode == .manual {
            manualClock = SubtitleClock(positionMs: Double(positionMs), uptime: uptime(), rate: 0, valid: true)
            manualPlaying = false
        }
        self.mode = mode
        onChange?()
    }

    func resetManualClock() {
        manualClock = SubtitleClock(positionMs: 0, uptime: uptime(), rate: 0, valid: true)
        manualPlaying = false
    }

    func togglePlay(durationMs: Int) {
        if activeSource == .tv { client.togglePlayPause(); return }
        manualClock.rebase(at: uptime())
        if !manualPlaying, durationMs > 0, manualClock.positionMs >= Double(durationMs) { manualClock.positionMs = 0 }
        manualPlaying.toggle()
        manualClock.rate = manualPlaying ? manualSpeed : 0
        onChange?()
    }

    func seek(toMs position: Int, durationMs: Int) {
        let bounded = max(0, durationMs > 0 ? min(durationMs, position) : position)
        if activeSource == .tv {
            client.seek(seconds: Double(bounded) / 1000)
            tracker.seek(toMs: bounded, uptime: uptime())
        } else {
            manualClock.positionMs = Double(bounded)
            manualClock.uptime = uptime()
        }
        onChange?()
    }

    func setManualSpeed(_ speed: Double) {
        guard speed.isFinite, speed > 0, speed <= 16 else { return }
        manualClock.rebase(at: uptime())
        manualSpeed = speed
        if manualPlaying { manualClock.rate = speed }
        onChange?()
    }

    /// Called by the display timer; the final frame is clamped before notifying the UI.
    func tick(durationMs: Int) {
        if activeSource == .manual, manualPlaying, durationMs > 0, positionMs >= durationMs {
            manualClock = SubtitleClock(positionMs: Double(durationMs), uptime: uptime(), rate: 0, valid: true)
            manualPlaying = false
        }
    }
}
