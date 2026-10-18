//
//  ContentView.swift
//  BetterDualSub
//

import SwiftUI
import AppKit
import CoreGraphics
import Combine
import UniformTypeIdentifiers
import Foundation
import MediaRemoteAdapter

/// Where the playback position comes from.
enum SyncMode: String, CaseIterable {
    case auto, manual
    static let storageKey = "syncMode"
    static var current: SyncMode { SyncMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto }
}

enum SyncSource { case tv, manual }

/// Which app's Now Playing clock drives the subtitles.
enum SyncTarget {
    static let key = "syncTargetBundleID"
    static let tvBundleID = "com.apple.TV"
    /// Follow whichever app is currently playing.
    static let anyApp = PlaybackTracker.anyApp
    private static let knownKey = "knownSyncApps"

    static var current: String { UserDefaults.standard.string(forKey: key) ?? tvBundleID }

    /// User-facing name of the chosen source.
    static var currentName: String {
        switch current {
        case tvBundleID: AppLocalization.string("sync.source.tv")
        case anyApp: AppLocalization.string("sync.status.anyPlayer")
        case let id: knownApps.first { $0.id == id }?.name ?? id
        }
    }

    static var knownApps: [SyncApp] {
        guard let data = UserDefaults.standard.data(forKey: knownKey),
              let apps = try? JSONDecoder().decode([SyncApp].self, from: data) else { return [] }
        return apps
    }

    /// Apps that have reported playback plus the apps running now, so a player can be chosen before it first plays.
    static var selectableApps: [SyncApp] {
        var apps = knownApps.filter { $0.id != tvBundleID }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let id = running.bundleIdentifier, id != tvBundleID, id != Bundle.main.bundleIdentifier,
                  !apps.contains(where: { $0.id == id }) else { continue }
            apps.append(SyncApp(id: id, name: running.localizedName ?? id))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func remember(_ app: SyncApp) {
        var apps = knownApps
        guard !apps.contains(where: { $0.id == app.id }) else { return }
        apps.append(app)
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: knownKey) }
    }

}

extension SyncStatus {
    var title: String {
        switch self {
        case .manual: AppLocalization.string("sync.status.manual")
        case .following(let app, let playing):
            AppLocalization.format("sync.status.following", app) + " · "
                + AppLocalization.string(playing ? "sync.status.playing" : "sync.status.paused")
        case .waiting: AppLocalization.format("sync.status.waiting", SyncTarget.currentName)
        case .disconnected: AppLocalization.string("sync.status.disconnected")
        }
    }

    /// What the user can do about it, if anything.
    var help: String? {
        switch self {
        case .manual: AppLocalization.string("sync.status.manual.help")
        case .following: nil
        case .waiting(let other?): AppLocalization.format("sync.status.otherApp.help", other.name, SyncTarget.currentName)
        case .waiting(nil): AppLocalization.format("sync.status.waiting.help", SyncTarget.currentName)
        case .disconnected: AppLocalization.string("sync.status.disconnected.help")
        }
    }
}

// Both subtitle tracks are driven by one clock: the Apple TV playback clock, or a manual one when TV is unavailable.
@MainActor
class SubtitleManager: ObservableObject {
    /// Shared with the overlay panel, which lives outside the SwiftUI scene graph.
    static let shared = SubtitleManager()
    static let manualSpeeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    @Published var currentText = ""
    @Published var secondaryText = ""
    @Published var isPlaying = false
    @Published var timeOffsetMs = 0 {
        didSet {
            let bounded = max(-86_400_000, min(86_400_000, timeOffsetMs))
            if timeOffsetMs != bounded { timeOffsetMs = bounded }
            if linkSecondaryDelay && secondaryOffsetMs != timeOffsetMs { secondaryOffsetMs = timeOffsetMs }
            saveOffsets()
            updateSub()
        }
    }
    @Published var secondaryOffsetMs = 0 {
        didSet {
            let bounded = max(-86_400_000, min(86_400_000, secondaryOffsetMs))
            if secondaryOffsetMs != bounded { secondaryOffsetMs = bounded }
            if linkSecondaryDelay && timeOffsetMs != secondaryOffsetMs { timeOffsetMs = secondaryOffsetMs }
            saveOffsets()
            updateSub()
        }
    }
    /// The timing saved for this title was restored when it was loaded.
    @Published private(set) var restoredTiming = false
    /// While on, Track B always has the same delay as Track A (changing either changes both). Persisted by `setLink`.
    @Published var linkSecondaryDelay = UserDefaults.standard.object(forKey: "linkSecondaryDelay") as? Bool ?? true
    @Published var debugTimeStr = "00:00"
    @Published var loadedTitle = ""
    @Published var trackNames: [String] = []
    /// Playback position (without subtitle offsets) and timeline length, for the manual progress bar.
    @Published var positionMs = 0
    @Published var durationMs = 0
    @Published var activeSource: SyncSource = .manual
    @Published var manualSpeed = 1.0
    @Published var manualPlaying = false
    /// Name of the app whose clock is currently followed, if any.
    @Published var syncedAppName: String?
    @Published private(set) var syncStatus: SyncStatus = .waiting(otherApp: nil)
    /// Speed the subtitles run at: the followed player's playback speed, or the manual clock's.
    @Published private(set) var playbackSpeed = 1.0
    /// Changes on every load, so work started for one set of subtitles is not applied to the next.
    @Published private(set) var loadID = UUID()
    @Published private(set) var recentSessions: [ViewingSession] = []
    @Published private(set) var historyError: String?
    @Published private(set) var canUndoSecondary = false
    private var currentSession: ViewingSession?
    private var previousSecondary: (document: SubtitleDocument?, name: String?, offset: Int, linked: Bool)?
    private let sessionStore = ViewingSessionStore(url: URL.applicationSupportDirectory
        .appendingPathComponent("BetterDualSub/RecentWatching.json"))
    private var sessionSaveTask: Task<Void, Never>?
    private var historyWriteTask: Task<Void, Never>?
    private var preferenceObserver: AnyCancellable?
    private var lastReportUptime: TimeInterval?
    private var diagnosticEvents: [[String: String]] = []
    /// Brief confirmation shown over the subtitles after an offset change.
    @Published var delayToast: String?
    private var toastTask: Task<Void, Never>?
    private var listenerAlive = true
    private var reconnectTask: Task<Void, Never>?
    /// Pending "playback lost" notice; brief gaps (between episodes, a seek) cancel it.
    private var lossTask: Task<Void, Never>?
    private var primary: SubtitleDocument?
    private var secondary: SubtitleDocument?
    /// The followed player's clock (called the TV clock, as Apple TV is the default player).
    private var tracker = PlaybackTracker()
    private var tvClock: SubtitleClock { tracker.clock }
    private let timingStore = SubtitleTimingStore(defaults: .standard)
    private var manualClock = SubtitleClock(positionMs: 0, uptime: 0, rate: 0, valid: true)
    /// Title the timing is saved under, once loading has restored it.
    private var timingTitle: String?
    private var internalTimer: Timer?
    private let mediaController = MediaController()
    private var appNapActivityToken: NSObjectProtocol?

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() {
        mediaController.onTrackInfoReceived = { [weak self] track in
            DispatchQueue.main.async { self?.receive(track) }
        }
        mediaController.onListenerTerminated = { [weak self] in
            DispatchQueue.main.async { self?.listenerTerminated() }
        }
        mediaController.onDecodingError = { [weak self] _, _ in
            DispatchQueue.main.async { self?.recordDiagnostic("decodeFailed"); self?.resetTVClock() }
        }
        mediaController.startListening()
        refreshSyncStatus()
        preferenceObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.queueSessionSave() }
        Task {
            do { recentSessions = try await sessionStore.load() }
            catch { historyError = error.localizedDescription }
        }
    }

    private func receive(_ track: TrackInfo?) {
        listenerAlive = true
        lastReportUptime = uptime
        let report = track.map {
            NowPlayingReport(bundleID: $0.payload.bundleIdentifier, appName: $0.payload.applicationName,
                             isPlaying: $0.payload.isPlaying, playbackRate: $0.payload.playbackRate,
                             elapsedMicros: $0.payload.elapsedTimeMicros, timestampEpochMicros: $0.payload.timestampEpochMicros,
                             durationMicros: $0.payload.durationMicros)
        }
        if let report, let app = report.app, report.elapsedMicros != nil {
            SyncTarget.remember(app)
        }
        guard tracker.receive(report, target: SyncTarget.current, uptime: uptime, epoch: Date().timeIntervalSince1970) else {
            recordDiagnostic(report == nil ? "noMedia" : (tracker.ignoredApp == nil ? "missingPosition" : "otherPlayer"))
            resetTVClock()
            return
        }
        syncedAppName = tracker.followedApp?.name
        durationMs = max(documentDurationMs, tracker.durationMs ?? 0)
        updateSub()
    }

    /// The helper process reading Now Playing exited unexpectedly; restart it after a short pause.
    private func listenerTerminated() {
        recordDiagnostic("listenerStopped")
        listenerAlive = false
        tracker.clearIgnoredApp()
        resetTVClock()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            // MediaRemoteAdapter can report the end of the process it replaces during its own periodic restart.
            // Reports arriving since then mean a listener is still running, and starting another would duplicate it.
            guard let self, !Task.isCancelled, !self.listenerAlive else { return }
            self.reconnect()
        }
    }

    /// Restarts reading system playback information. It only applies while disconnected: the listener ignores
    /// a start while it is still running.
    func reconnect() {
        recordDiagnostic("reconnect")
        reconnectTask?.cancel()
        reconnectTask = nil
        mediaController.startListening()
        listenerAlive = true
        refreshNowPlaying()
    }

    /// Asks for the current Now Playing state at once; the listener itself only reports changes.
    private func refreshNowPlaying() {
        mediaController.getTrackInfo { [weak self] track in
            DispatchQueue.main.async { self?.receive(track) }
        }
    }

    /// Follows `app` from now on (offered when another player is the one playing).
    func follow(_ app: SyncApp) {
        SyncTarget.remember(app)
        UserDefaults.standard.set(app.id, forKey: SyncTarget.key)
        syncTargetDidChange()
    }

    private func startSubtitleTimerIfNeeded() {
        guard internalTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSub() }
        }
        RunLoop.main.add(timer, forMode: .common)
        internalTimer = timer
    }

    private func resetTVClock() {
        let now = uptime
        if activeSource == .tv, tvClock.valid {
            // Preserve the latest followed-player position before invalidating it; fallback should
            // not jump to the manual clock's older position (often zero).
            manualClock = SubtitleClock(positionMs: Double(tvClock.position(at: now)), uptime: now, rate: 0, valid: true)
            manualPlaying = false
        }
        tracker.invalidate()
        syncedAppName = nil
        durationMs = documentDurationMs
        updateSub()
    }

    func syncTargetDidChange() {
        tracker.clearIgnoredApp()
        resetTVClock()
        refreshNowPlaying()
    }

    private func refreshSyncStatus() {
        let speed = activeSource == .tv ? tracker.playbackRate : manualSpeed
        if playbackSpeed != speed { playbackSpeed = speed }
        let status = SyncStatus.current(manualMode: SyncMode.current == .manual, listenerAlive: listenerAlive,
                                        followedApp: activeSource == .tv ? syncedAppName : nil,
                                        playing: tvClock.rate > 0, ignoredApp: tracker.ignoredApp)
        guard status != syncStatus else { return }
        let wasFollowing = syncStatus.isFollowing
        syncStatus = status
        recordDiagnostic(status.isFollowing ? "following" : "notFollowing")
        guard !trackNames.isEmpty, wasFollowing != status.isFollowing else { return }
        if status.isFollowing {
            // A gap shorter than the notice delay is not worth mentioning, and neither is its end.
            if let lossTask { lossTask.cancel(); self.lossTask = nil; return }
            showToast(status.title)
        } else if status != .manual {
            lossTask?.cancel()
            lossTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.lossTask = nil
                guard !self.syncStatus.isFollowing, self.syncStatus != .manual else { return }
                self.showToast(AppLocalization.format("sync.toast.lost", SyncTarget.currentName), seconds: 3)
            }
        }
    }

    private func updateSub() {
        let now = uptime
        let source: SyncSource
        switch SyncMode.current {
        case .manual: source = .manual
        // TV keeps the clock until it reports nothing playing; the anchor extrapolates between reports.
        case .auto: source = tvClock.valid ? .tv : .manual
        }
        if source != activeSource {
            if source == .manual, tvClock.valid {
                // Continue from where TV was instead of jumping back to the start.
                manualClock = SubtitleClock(positionMs: Double(tvClock.position(at: now)), uptime: now, rate: 0, valid: true)
                manualPlaying = false
            }
            activeSource = source
        }
        let position = source == .tv ? tvClock.position(at: now) : manualClock.position(at: now)
        let playing = source == .tv ? tvClock.rate > 0 : manualPlaying
        if isPlaying != playing { isPlaying = playing }
        if playing && !trackNames.isEmpty {
            if appNapActivityToken == nil {
                appNapActivityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated], reason: "Synchronize subtitles with playback."
                )
            }
        } else if let token = appNapActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            appNapActivityToken = nil
        }
        if source == .manual, durationMs > 0, position >= durationMs, manualPlaying {
            manualPlaying = false
            manualClock.positionMs = Double(durationMs)
            manualClock.uptime = now
            manualClock.rate = 0
        }
        if abs(positionMs - position) >= 100 || (position == 0) != (positionMs == 0) { positionMs = position }
        let formatted = String(format: "%02d:%02d:%02d", position / 3_600_000, position / 60_000 % 60, position / 1000 % 60)
        if debugTimeStr != formatted { debugTimeStr = formatted }
        // The video position already runs at the player's speed, so the subtitles follow it 1:1, minus the delay.
        let first = primary?.text(at: position - timeOffsetMs) ?? ""
        let second = secondary?.text(at: position - secondaryOffsetMs) ?? ""
        if currentText != first { currentText = first }
        if secondaryText != second { secondaryText = second }
        refreshSyncStatus()
    }

    // MARK: Playback controls (manual clock, or the followed player through Now Playing commands)

    /// Cues of a track ("primary" / "secondary") for the alignment picker.
    func cues(track: String) -> [SubtitleItem] { (track == "secondary" ? secondary : primary)?.items ?? [] }

    /// Current playback position in ms, before any subtitle delay.
    func currentPositionMs() -> Int {
        activeSource == .tv ? tvClock.position(at: uptime) : manualClock.position(at: uptime)
    }

    /// Times `track` so that `cue` is the line on screen right now (cue at 8:00 while playing at 10:00 -> +2:00).
    /// Returns the new delay. Subtitle time runs 1:1 with video time, so only the delay changes.
    @discardableResult
    func align(track: String, to cue: SubtitleItem) -> Int {
        setDelay(track: track, ms: currentPositionMs() - cue.startMs)
        return track == "secondary" ? secondaryOffsetMs : timeOffsetMs
    }

    private var documentDurationMs: Int {
        max(primary?.duration ?? 0, secondary?.duration ?? 0)
    }

    func togglePlay() {
        if activeSource == .tv { mediaController.togglePlayPause() } else { toggleManualPlay() }
    }

    func seek(toMs target: Int) {
        guard activeSource == .tv else { seekManual(toMs: target); return }
        let bounded = max(0, durationMs > 0 ? min(durationMs, target) : target)
        mediaController.setTime(seconds: Double(bounded) / 1000)
        // Show the new position right away; the player's next report confirms it.
        tracker.seek(toMs: bounded, uptime: uptime)
        positionMs = bounded
        updateSub()
    }

    func seek(byMs delta: Int) {
        seek(toMs: (activeSource == .tv ? tvClock.position(at: uptime) : manualClock.position(at: uptime)) + delta)
    }

    // MARK: Manual clock

    func toggleManualPlay() {
        let now = uptime
        manualClock.rebase(at: now)
        if manualPlaying {
            manualClock.rate = 0
        } else {
            if durationMs > 0, Int(manualClock.positionMs) >= durationMs { manualClock.positionMs = 0 }
            manualClock.rate = manualSpeed
        }
        manualPlaying.toggle()
        updateSub()
    }

    func seekManual(toMs target: Int) {
        manualClock.positionMs = Double(max(0, min(durationMs > 0 ? durationMs : target, target)))
        manualClock.uptime = uptime
        positionMs = Int(manualClock.positionMs)
        updateSub()
    }

    func seekManual(byMs delta: Int) {
        seekManual(toMs: manualClock.position(at: uptime) + delta)
    }

    func setManualSpeed(_ speed: Double) {
        manualClock.rebase(at: uptime)
        manualSpeed = speed
        if manualPlaying { manualClock.rate = speed }
        updateSub()
    }

    /// Pauses extrapolation while the progress bar is being dragged; returns whether it was playing.
    func beginScrub() -> Bool {
        let was = manualPlaying
        if was { toggleManualPlay() }
        return was
    }

    func endScrub(resume: Bool) {
        if resume && !manualPlaying { toggleManualPlay() }
    }

    func setSyncMode(_ mode: SyncMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: SyncMode.storageKey)
        updateSub()
    }

    // MARK: Loading and offsets

    func load(primary: SubtitleDocument, secondary: SubtitleDocument? = nil, title: String, names: [String],
              sourceID: String = "file", restoring: ViewingSession? = nil) {
        if let snapshot = sessionSnapshot() { writeSession(snapshot) }
        sessionSaveTask?.cancel()
        SubtitleTranslator.shared.cancel()
        previousSecondary = nil
        canUndoSecondary = false
        var session = restoring ?? ViewingSession(primary: primary, secondary: secondary, title: title, names: names, sourceID: sourceID)
        session.openedAt = Date()
        currentSession = nil
        if let restoring {
            ViewingDisplaySettings.restore(restoring.display, to: .standard)
            SubtitleScreenPreferences.acceptRestoredSettings()
            linkSecondaryDelay = restoring.linked
        }
        startSubtitleTimerIfNeeded()
        self.primary = primary
        self.secondary = secondary
        loadID = UUID()
        loadedTitle = title
        trackNames = names
        currentText = ""
        secondaryText = ""
        durationMs = documentDurationMs
        manualClock = SubtitleClock(positionMs: 0, uptime: uptime, rate: 0, valid: true)
        manualPlaying = false
        timingTitle = nil
        let timingKey = "session." + session.id
        let saved = restoring?.timing ?? timingStore.load(sessionID: session.id, legacyTitle: title)
        timeOffsetMs = saved.primaryOffsetMs
        secondaryOffsetMs = linkSecondaryDelay ? saved.primaryOffsetMs : saved.secondaryOffsetMs
        timingTitle = timingKey
        currentSession = session
        restoredTiming = timeOffsetMs != 0 || secondaryOffsetMs != 0
        // Loading subtitles means the user wants to see them, even if the window was hidden earlier.
        if !OverlayController.isVisible { OverlayController.setVisible(true) }
        updateSub()
        if restoredTiming { showToast(AppLocalization.format("timing.restored.toast", timingSummary), seconds: 3) }
        recordDiagnostic(restoring == nil ? "loaded" : "restored")
        queueSessionSave()
    }

    /// Delay of each track, such as "+1200 ms" or, for different tracks, both joined by " / ".
    var timingSummary: String {
        let first = String(format: "%+d ms", timeOffsetMs)
        guard secondary != nil, secondaryOffsetMs != timeOffsetMs else { return first }
        return first + " / " + String(format: "%+d ms", secondaryOffsetMs)
    }

    /// The loaded Track 1, as the source for a translated Track 2.
    var primaryDocument: SubtitleDocument? { primary }

    /// Replaces Track 2 with `document`, which has Track 1's timing (a translation of it), so it also takes Track 1's delay.
    func setSecondary(_ document: SubtitleDocument, name: String) {
        guard !trackNames.isEmpty else { return }
        previousSecondary = (secondary, trackNames.count > 1 ? trackNames[1] : nil, secondaryOffsetMs, linkSecondaryDelay)
        canUndoSecondary = true
        secondary = document
        trackNames = [trackNames[0], name]
        durationMs = max(durationMs, documentDurationMs)
        secondaryOffsetMs = timeOffsetMs
        updateSub()
        queueSessionSave()
    }

    func undoSecondary() {
        guard let previousSecondary else { return }
        secondary = previousSecondary.document
        trackNames = [trackNames[0]] + (previousSecondary.name.map { [$0] } ?? [])
        linkSecondaryDelay = previousSecondary.linked
        secondaryOffsetMs = previousSecondary.offset
        self.previousSecondary = nil
        canUndoSecondary = false
        durationMs = max(documentDurationMs, tracker.durationMs ?? 0)
        updateSub()
        queueSessionSave()
    }

    func restoreSession(_ session: ViewingSession) {
        do {
            let first = try SubtitleDocument(text: session.primarySRT)
            let second = try session.secondarySRT.map { try SubtitleDocument(text: $0) }
            guard session.names.count == (second == nil ? 1 : 2) else { throw SubtitleError.message("error.history.invalid") }
            load(primary: first, secondary: second, title: session.title, names: session.names, restoring: session)
            // Ask the player for its present position. Never seek the video to an old session position.
            refreshNowPlaying()
            showControlCenterPage("nowPlaying")
        } catch { historyError = error.localizedDescription }
    }

    func removeSession(id: String?) {
        sessionSaveTask?.cancel()
        let removedIDs = id.map { [$0] } ?? recentSessions.map(\.id)
        if id == nil || currentSession?.id == id { currentSession = nil; timingTitle = nil }
        let previousWrite = historyWriteTask
        historyWriteTask = Task {
            await previousWrite?.value
            do {
                recentSessions = try await sessionStore.remove(id: id)
                for id in removedIDs { timingStore.save(SavedTiming(), title: "session." + id) }
                historyError = nil
            }
            catch { historyError = error.localizedDescription }
        }
    }

    private func sessionSnapshot() -> ViewingSession? {
        guard var session = currentSession, let primary else { return nil }
        SubtitleScreenPreferences.saveCurrentLayout()
        session.primarySRT = primary.srt
        session.secondarySRT = secondary?.srt
        session.names = trackNames
        session.timing = SavedTiming(primaryOffsetMs: timeOffsetMs, secondaryOffsetMs: secondaryOffsetMs)
        session.linked = linkSecondaryDelay
        session.display = ViewingDisplaySettings.capture(.standard)
        return session
    }

    private func writeSession(_ session: ViewingSession) {
        let previousWrite = historyWriteTask
        historyWriteTask = Task {
            await previousWrite?.value
            do { recentSessions = try await sessionStore.record(session); historyError = nil }
            catch { historyError = error.localizedDescription }
        }
    }

    private func queueSessionSave() {
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let session = self.sessionSnapshot() else { return }
            self.writeSession(session)
        }
    }

    func flushHistory() async {
        sessionSaveTask?.cancel()
        if let session = sessionSnapshot() { writeSession(session) }
        await historyWriteTask?.value
    }

    var subtitleHealthKey: String {
        guard let primary else { return "health.noSubtitles" }
        if syncStatus == .manual { return "health.manual" }
        if !syncStatus.isFollowing { return "health.noClock" }
        if !currentText.isEmpty || !secondaryText.isEmpty { return "health.cue" }
        let start = min((primary.items.first?.startMs ?? 0) + timeOffsetMs,
                        secondary.map { ($0.items.first?.startMs ?? 0) + secondaryOffsetMs } ?? Int.max)
        let end = max(primary.duration + timeOffsetMs, secondary.map { $0.duration + secondaryOffsetMs } ?? Int.min)
        let time = currentPositionMs()
        if time < start || time >= end { return "health.outside" }
        return "health.gap"
    }

    private func recordDiagnostic(_ event: String) {
        guard diagnosticEvents.last?["event"] != event else { return }
        diagnosticEvents.append(["event": event, "time": ISO8601DateFormatter().string(from: Date())])
        diagnosticEvents = Array(diagnosticEvents.suffix(30))
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BetterDualSub-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Intentionally exclude subtitle text, titles, file paths, source URLs and account identifiers.
        var snapshot: [String: Any] = ["version": Bundle.main.appVersion,
            "system": ProcessInfo.processInfo.operatingSystemVersionString, "time": ISO8601DateFormatter().string(from: Date()),
            "listenerAlive": listenerAlive, "mode": SyncMode.current.rawValue, "target": SyncTarget.current,
            "following": syncStatus.isFollowing, "playing": isPlaying, "positionMs": currentPositionMs(),
            "rate": playbackSpeed, "primaryCueCount": primary?.items.count ?? 0, "secondaryCueCount": secondary?.items.count ?? 0,
            "primaryOffsetMs": timeOffsetMs, "secondaryOffsetMs": secondaryOffsetMs, "health": subtitleHealthKey,
            "events": diagnosticEvents]
        if let lastReportUptime { snapshot["lastReportAgeSeconds"] = max(0, uptime - lastReportUptime) }
        do { try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }

    private func saveOffsets() {
        guard let title = timingTitle else { return }
        timingStore.save(SavedTiming(primaryOffsetMs: timeOffsetMs, secondaryOffsetMs: secondaryOffsetMs), title: title)
        queueSessionSave()
    }

    func adjustDelay(track: String, delta: Int) {
        let current = track == "secondary" ? secondaryOffsetMs : timeOffsetMs
        setDelay(track: track, ms: delta == Int.min ? 0 : current + delta)
    }

    /// Sets a track's delay outright (typed value, reset, or a step) and confirms it on screen.
    func setDelay(track: String, ms: Int) {
        let secondaryTrack = track == "secondary"
        if secondaryTrack { secondaryOffsetMs = ms } else { timeOffsetMs = ms }
        let value = String(format: "%+d ms", secondaryTrack ? secondaryOffsetMs : timeOffsetMs)
        let key = linkSecondaryDelay && secondary != nil ? "delay.toast.linked" : (secondaryTrack ? "delay.toast.secondary" : "delay.toast.primary")
        showToast(AppLocalization.format(key, value))
    }

    func showToast(_ text: String, seconds: Double = 1.6) {
        delayToast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.delayToast = nil
        }
    }

    func setLink(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "linkSecondaryDelay")
        linkSecondaryDelay = on
        if on { secondaryOffsetMs = timeOffsetMs }
    }

    /// For loaders that supply a file-level delay and an extra delay for Track B (B = A + extra).
    func applyDelays(primary: Int, secondaryExtra: Int) {
        linkSecondaryDelay = secondaryExtra == 0 ? UserDefaults.standard.object(forKey: "linkSecondaryDelay") as? Bool ?? true : false
        timeOffsetMs = primary
        secondaryOffsetMs = linkSecondaryDelay ? primary : primary + secondaryExtra
        // The delays given here replace any restored ones, so the "restored" notice no longer applies.
        if restoredTiming { delayToast = nil }
        restoredTiming = false
    }

}

// MARK: - 2. Crisp black-outlined text component
struct HTMLStrokeText: View {
    let rawText: String
    let fontSize: CGFloat
    let style: SubtitleTrackStyle
    var lineMode: SubtitleLineMode = .original
    
    private var customNSFont: NSFont {
        let weightOption = FontWeightOption(rawValue: style.weight) ?? .regular
        var fontDescriptor = NSFontDescriptor(fontAttributes: [.family: style.family])
        
        var traits: NSFontDescriptor.SymbolicTraits = []
        if weightOption == .bold || weightOption == .heavy {
            traits.insert(.bold)
        }
        
        if !traits.isEmpty {
            fontDescriptor = fontDescriptor.withSymbolicTraits(traits)
        }
        
        fontDescriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weightOption.nsWeight]
        ])
        
        return NSFont(descriptor: fontDescriptor, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: weightOption.nsWeight)
    }
    
    private var attributedString: NSAttributedString {
        var cleanRawText = SubtitleDocument.displayHTML(lineMode.apply(to: rawText))
        
        if style.weight == FontWeightOption.regular.rawValue {
            cleanRawText = cleanRawText.replacingOccurrences(of: "<b>", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "</b>", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "<strong>", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "</strong>", with: "", options: .caseInsensitive)
        }
        
        let htmlData = Data(cleanRawText.utf8)
        // AppKit stores stroke width as a percentage of the font size.
        let strokePercent = fontSize > 0 ? -100 * style.outlinePixels / fontSize : 0
        if let nsAttributedString = try? NSMutableAttributedString(
            data: htmlData,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) {
            let range = NSRange(location: 0, length: nsAttributedString.length)
            
            nsAttributedString.removeAttribute(.font, range: range)
            nsAttributedString.addAttributes([
                .font: customNSFont,
                .foregroundColor: NSColor(hex: style.textColor),
                .strokeColor: NSColor(hex: style.outlineColor),
                .strokeWidth: strokePercent
            ], range: range)

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineSpacing = 4
            nsAttributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            return nsAttributedString
        }

        return NSAttributedString(string: cleanRawText, attributes: [
            .font: customNSFont,
            .foregroundColor: NSColor(hex: style.textColor),
            .strokeColor: NSColor(hex: style.outlineColor),
            .strokeWidth: strokePercent
        ])
    }
    
    var body: some View {
        OutlinedSubtitleLabel(attributedString: attributedString, fitSingleLine: lineMode == .single)
    }
}

private struct OutlinedSubtitleLabel: NSViewRepresentable {
    let attributedString: NSAttributedString
    /// Shrink the text (down to half size) instead of wrapping when a single line is too wide.
    var fitSingleLine = false

    final class Coordinator { var width: CGFloat = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: attributedString)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.attributedStringValue = fitted(to: context.coordinator.width)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
    }

    private static let horizontalMargin: CGFloat = 12, verticalMargin: CGFloat = 6

    private func fitted(to width: CGFloat) -> NSAttributedString {
        guard fitSingleLine, width > Self.horizontalMargin else { return attributedString }
        let available = width - Self.horizontalMargin
        let natural = attributedString.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        guard natural > available, natural > 0 else { return attributedString }
        let scale = max(0.5, available / natural)
        let scaled = NSMutableAttributedString(attributedString: attributedString)
        scaled.enumerateAttribute(.font, in: NSRange(location: 0, length: scaled.length)) { value, range, _ in
            if let font = value as? NSFont {
                scaled.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font, range: range)
            }
        }
        return scaled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nsView.intrinsicContentSize }
        context.coordinator.width = width
        let text = fitted(to: width)
        if nsView.attributedStringValue != text { nsView.attributedStringValue = text }
        // NSTextField insets its text and the outline spills past the glyphs, so measure inside a smaller box
        // and add the margins back; otherwise the last characters wrap onto a line that is clipped.
        let bounds = text.boundingRect(
            with: NSSize(width: max(1, width - Self.horizontalMargin), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: min(width, ceil(bounds.width) + Self.horizontalMargin),
                      height: ceil(bounds.height) + Self.verticalMargin)
    }
}

// MARK: - 3. Transparent SwiftUI overlay
struct ContentView: View {
    @EnvironmentObject var subManager: SubtitleManager
    @AppStorage("primaryFontSize") private var primaryFontSize = SubtitleAppearanceDefaults.fontSize(secondary: false)
    @AppStorage("secondaryFontSize") private var secondaryFontSize = SubtitleAppearanceDefaults.fontSize(secondary: true)
    @AppStorage("primaryFontFamily") private var primaryFontFamily = UserDefaults.standard.string(forKey: "selectedFontFamily") ?? "Helvetica Neue"
    @AppStorage("secondaryFontFamily") private var secondaryFontFamily = "Helvetica Neue"
    @AppStorage("primaryFontWeight") private var primaryFontWeight = UserDefaults.standard.string(forKey: "selectedFontWeight") ?? "Bold"
    @AppStorage("secondaryFontWeight") private var secondaryFontWeight = "Regular"
    @AppStorage("primaryTextColor") private var primaryTextColor = "#FFFFFF"
    @AppStorage("secondaryTextColor") private var secondaryTextColor = "#FFFFFF"
    @AppStorage("primaryOutlineColor") private var primaryOutlineColor = "#000000"
    @AppStorage("secondaryOutlineColor") private var secondaryOutlineColor = "#000000"
    @AppStorage("primaryOutlinePixels") private var primaryOutlinePixels = SubtitleAppearanceDefaults.outlinePixels(secondary: false)
    @AppStorage("secondaryOutlinePixels") private var secondaryOutlinePixels = SubtitleAppearanceDefaults.outlinePixels(secondary: true)
    @AppStorage("primaryLineMode") private var primaryLineMode = SubtitleLineMode.defaultValue.rawValue
    @AppStorage("secondaryLineMode") private var secondaryLineMode = SubtitleLineMode.defaultValue.rawValue
    @AppStorage("backgroundStyle") private var backgroundStyle: String = BackgroundStyleOption.transparent.rawValue
    @AppStorage(SubtitleAppearanceDefaults.backgroundColorKey) private var backgroundColor = SubtitleAppearanceDefaults.backgroundColor
    @AppStorage(SubtitleAppearanceDefaults.backgroundOpacityKey) private var backgroundOpacity = SubtitleAppearanceDefaults.backgroundOpacity
    @AppStorage(SubtitleAppearanceDefaults.backgroundRadiusKey) private var backgroundRadius = SubtitleAppearanceDefaults.backgroundRadius
    @AppStorage("subtitleOffsetX") private var offsetX: Double = 0
    @AppStorage("subtitleOffsetY") private var offsetY: Double = 0
    @AppStorage("showSubtitlePreview") private var showSubtitlePreview = true
    @ObservedObject private var overlay = OverlayController.shared

    @State private var tvWindowSize: CGSize = CGSize(width: 800, height: 450)
    @State private var dragTranslation: CGSize = .zero
    @State private var textSize: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @State private var placementTimer: Timer?

    private var primaryDisplayText: String {
        if !subManager.currentText.isEmpty { return subManager.currentText }
        if subManager.trackNames.isEmpty && showSubtitlePreview { return "A subtitle preview" }
        // Keep the window visible (and draggable) while there is nothing to show yet.
        guard subManager.secondaryText.isEmpty else { return "" }
        if subManager.trackNames.isEmpty { return AppLocalization.string("overlay.placeholder.idle") }
        return subManager.isPlaying ? "" : AppLocalization.string("overlay.placeholder.waiting")
    }

    private var secondaryDisplayText: String {
        if !subManager.secondaryText.isEmpty { return subManager.secondaryText }
        guard subManager.currentText.isEmpty else { return "" }
        // Keep the empty overlay as one draggable preview. Both styles remain visible on the Appearance page.
        if subManager.trackNames.isEmpty { return "" }
        if subManager.trackNames.count > 1 && !subManager.isPlaying { return AppLocalization.string("overlay.placeholder.secondary") }
        return ""
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            bubble
                .padding(.bottom, tvWindowSize.height * 0.02)
                .offset(x: offsetX * tvWindowSize.width + dragTranslation.width,
                        y: offsetY * tvWindowSize.height + dragTranslation.height)
        }
        .background(Color.clear)
        .onAppear {
            startOverlayPlacement()
            overlay.startHitTesting()
            overlay.hitRects = hitRectsInWindow
            overlay.needsDwell = !hasCue
        }
        .onDisappear {
            placementTimer?.invalidate()
            placementTimer = nil
            overlay.stopHitTesting()
        }
        .onChange(of: hitRectsInWindow) { _, rects in overlay.hitRects = rects }
        .onChange(of: hasCue) { _, value in overlay.needsDwell = !value }
        .onReceive(NotificationCenter.default.publisher(for: .adjustSubtitleDelay)) { note in
            guard let track = note.userInfo?["track"] as? String, let delta = note.userInfo?["delta"] as? Int else { return }
            subManager.adjustDelay(track: track, delta: delta)
        }
        .onReceive(NotificationCenter.default.publisher(for: .manualPlaybackCommand)) { note in
            guard let raw = note.userInfo?["action"] as? Int, let action = SubtitleShortcutAction(rawValue: raw),
                  !subManager.trackNames.isEmpty else { return }
            switch action {
            case .manualPlayPause: subManager.togglePlay()
            case .manualBack: subManager.seek(byMs: -10_000)
            case .manualForward: subManager.seek(byMs: 10_000)
            default: break
            }
        }
    }

    /// A real cue (not a placeholder) is on screen.
    private var hasCue: Bool { !subManager.currentText.isEmpty || !subManager.secondaryText.isEmpty }

    /// Areas that must take the mouse, in window coordinates (top-left origin): the visible subtitle box and, while shown,
    /// the control bar. Everything else (gaps, the toast, empty corners) stays click-through.
    private var hitRectsInWindow: [CGRect] {
        guard textSize != .zero else { return [] }
        let width = tvWindowSize.width, height = tvWindowSize.height
        let centerX = width / 2 + offsetX * width + dragTranslation.width
        let bottom = height - height * 0.02 + offsetY * height + dragTranslation.height
        var rects = [CGRect(x: centerX - textSize.width / 2, y: bottom - textSize.height, width: textSize.width, height: textSize.height)]
        if barSize != .zero {
            rects.append(CGRect(x: centerX - barSize.width / 2, y: bottom - textSize.height - 6 - barSize.height,
                                width: barSize.width, height: barSize.height))
        }
        return rects
    }

    /// Control bar (manual mode, on hover) above the subtitle text; the whole stack is the hover region.
    private var bubble: some View {
        let showBar = !subManager.trackNames.isEmpty && (overlay.isHovering || overlay.isDragging || overlay.isEditing || overlay.isAligning)
        return VStack(spacing: 6) {
            if showBar {
                ManualControlBar(manager: subManager)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { barSize = proxy.size }
                            .onChange(of: proxy.size) { _, size in barSize = size }
                            .onDisappear { barSize = .zero }
                    })
            }
            textBubble
        }
        .overlay(alignment: .top) {
            if let toast = subManager.delayToast {
                Text(verbatim: toast)
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.black.opacity(0.3)), in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .fixedSize()
                    .offset(y: -40)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: subManager.delayToast)
    }

    private var textBubble: some View {
        let hasText = !primaryDisplayText.isEmpty || !secondaryDisplayText.isEmpty
        // With no cue on screen, keep an empty box about the size of the usual subtitle so the background (and hover target) stay put.
        let primarySize = max(SubtitleAppearanceLimits.minimumFontSize, primaryFontSize)
        let secondarySize = max(SubtitleAppearanceLimits.minimumFontSize, secondaryFontSize)
        let emptyHeight = (primarySize + (subManager.trackNames.count > 1 ? secondarySize + 5 : 0)) * 1.4 + 16
        return VStack(spacing: 5) {
            if !primaryDisplayText.isEmpty {
                HTMLStrokeText(rawText: primaryDisplayText,
                               fontSize: primarySize, style: primaryStyle,
                               lineMode: SubtitleLineMode(rawValue: primaryLineMode) ?? .original)
            }
            if !secondaryDisplayText.isEmpty {
                HTMLStrokeText(rawText: secondaryDisplayText,
                               fontSize: secondarySize, style: secondaryStyle,
                               lineMode: SubtitleLineMode(rawValue: secondaryLineMode) ?? .original)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minWidth: hasText ? 0 : tvWindowSize.width * 0.4, minHeight: hasText ? 0 : emptyHeight)
        .background(
            SubtitleBackgroundView(style: backgroundStyle, colorHex: backgroundColor,
                                   opacity: backgroundOpacity, radius: backgroundRadius)
        )
        // Measured before the max-width frame below, which is much wider than the visible box.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { textSize = proxy.size }
                .onChange(of: proxy.size) { _, size in textSize = size }
        })
        .overlay {
            do {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(overlay.isHovering || overlay.isDragging ? 0.7 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                OverlayDragHandle(
                    onDrag: { dragTranslation = $0; overlay.isDragging = true },
                    onEnd: {
                        offsetX = min(0.45, max(-0.45, offsetX + dragTranslation.width / max(1, tvWindowSize.width)))
                        offsetY = min(0.02, max(-0.95, offsetY + dragTranslation.height / max(1, tvWindowSize.height)))
                        dragTranslation = .zero
                        overlay.isDragging = false
                    },
                    onHide: { OverlayController.setVisible(false) },
                    onReset: { OverlayController.resetPosition() }
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if overlay.isHovering && !overlay.isDragging {
                Button { OverlayController.setVisible(false) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: Circle())
                        .environment(\.colorScheme, .dark)
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        // Constrain the width last so the border, drag area and close button hug the visible subtitle box.
        .frame(maxWidth: tvWindowSize.width * 0.9)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var primaryStyle: SubtitleTrackStyle {
        SubtitleTrackStyle(family: primaryFontFamily, weight: primaryFontWeight,
                           textColor: primaryTextColor, outlineColor: primaryOutlineColor, outlinePixels: primaryOutlinePixels)
    }

    private var secondaryStyle: SubtitleTrackStyle {
        SubtitleTrackStyle(family: secondaryFontFamily, weight: secondaryFontWeight,
                           textColor: secondaryTextColor, outlineColor: secondaryOutlineColor, outlinePixels: secondaryOutlinePixels)
    }
    
    // Helper that checks for full screen
    private func checkIfAppleTVIsFullScreen(tvRect: CGRect) -> Bool {
        let currentScreen = NSScreen.screens.first(where: { $0.frame.intersects(tvRect) }) ?? NSScreen.main
        guard let screenSize = currentScreen?.frame.size else { return false }
        
        return abs(tvRect.width - screenSize.width) < 15 && abs(tvRect.height - screenSize.height) < 15
    }
    
    
    // MARK: - Overlay placement
    /// Uses the chosen screen (or the current main screen) and remembers each display's free placement.
    private func startOverlayPlacement() {
        guard placementTimer == nil else { return }
        placementTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == OverlayPanel.identifierValue }) else { return }

                guard OverlayController.isVisible else {
                    if window.isVisible { window.orderOut(nil) }
                    return
                }
                guard let screen = SubtitleScreenPreferences.selectedScreen else { return }
                SubtitleScreenPreferences.prepare(screen)
                let targetFrame = screen.visibleFrame

                if self.tvWindowSize != targetFrame.size {
                    DispatchQueue.main.async { self.tvWindowSize = targetFrame.size }
                }

                let requiredBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                if window.collectionBehavior != requiredBehavior { window.collectionBehavior = requiredBehavior }
                if window.level != .mainMenu { window.level = .mainMenu }
                if window.frame != targetFrame { window.setFrame(targetFrame, display: true, animate: false) }
                if !window.isVisible { window.orderFrontRegardless() }
            }
        }
    }
}

// MARK: - 4. Blur effect background helper
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow // Use a semantic material instead of .dark
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        
        // Force the effect to render in the dark tone (Vibrant Dark)
        visualEffectView.appearance = NSAppearance(named: .vibrantDark)
        
        return visualEffectView
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.appearance = NSAppearance(named: .vibrantDark)
    }
}

// Identify the overlay explicitly so docking never moves the download window.
/// Borderless, click-through-by-default panel for the subtitles. Non-activating, so clicking the subtitles
/// does not bring the app's other windows (the control center) to the front.
final class OverlayPanel: NSPanel {
    static let identifierValue = "subtitle-overlay"

    init() {
        super.init(contentRect: NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 450),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier(Self.identifierValue)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .mainMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        contentView = NSHostingView(rootView: OverlayRootView())
    }

    /// Only while a text field is being edited, so clicking the subtitles never steals keyboard focus from the player.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

private struct OverlayRootView: View {
    @AppStorage(AppLocalization.languagePreferenceKey) private var language = AppLocalization.defaultLanguage

    var body: some View {
        ContentView()
            .environmentObject(SubtitleManager.shared)
            .environment(\.locale, Locale(identifier: language))
    }
}

// MARK: - 5. Free-position overlay support
/// Shared state for the draggable subtitle window.
@MainActor
final class OverlayController: ObservableObject {
    static let shared = OverlayController()
    nonisolated static let visibleKey = "showSubtitleWindow"

    @Published var isHovering = false
    @Published var isDragging = false
    /// A text field in the control bar has focus; keep the bar open and the panel interactive.
    @Published var isEditing = false
    /// The line-alignment panel is open: the bar stays up until it is closed, but only takes the mouse while pointed at.
    @Published var isAligning = false
    var hitRects: [CGRect] = []
    /// With no real cue on screen the subtitle box is just an empty frame; only capture the mouse once the pointer rests in it.
    var needsDwell = false
    private var enteredAt: TimeInterval?
    private var timer: Timer?
    private var lastInside: TimeInterval = -.infinity

    nonisolated static var isVisible: Bool {
        UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? true
    }

    nonisolated static let lockedKey = "subtitleOverlayLocked"

    /// While locked the overlay never takes the mouse, so everything under it stays usable.
    nonisolated static var isLocked: Bool { UserDefaults.standard.bool(forKey: lockedKey) }

    static func setLocked(_ locked: Bool) {
        UserDefaults.standard.set(locked, forKey: lockedKey)
        NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil)
        shared.isHovering = false
        if locked { shared.isAligning = false }
        SubtitleManager.shared.showToast(AppLocalization.string(locked ? "overlay.locked.toast" : "overlay.unlocked.toast"))
    }

    static func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: visibleKey)
        NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil)
    }

    static func resetPosition() {
        UserDefaults.standard.set(0.0, forKey: "subtitleOffsetX")
        UserDefaults.standard.set(0.0, forKey: "subtitleOffsetY")
    }

    /// The overlay ignores the mouse so TV.app stays clickable; it only accepts clicks while the pointer is over the subtitles.
    func startHitTesting() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitTesting() }
        }
    }

    func stopHitTesting() {
        timer?.invalidate()
        timer = nil
        isHovering = false
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == OverlayPanel.identifierValue }) {
            window.ignoresMouseEvents = true
        }
    }

    private func updateHitTesting() {
        guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "subtitle-overlay" }),
              window.isVisible else {
            if isHovering { isHovering = false }
            return
        }
        if Self.isLocked {
            if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
            if isHovering { isHovering = false }
            if isEditing { isEditing = false }
            if isAligning { isAligning = false }
            return
        }
        // Clicking another app while a bar field has focus leaves its field editor in place, so editing never ends on
        // its own and the panel (which covers the whole screen) would keep taking every click. Finish the edit instead.
        if isEditing, !window.isKeyWindow {
            window.makeFirstResponder(nil)
            isEditing = false
        }
        if NSEvent.pressedMouseButtons != 0 { return }
        let mouse = NSEvent.mouseLocation
        let inside = hitRects.contains { rect in
            let r = rect.insetBy(dx: -4, dy: -4)
            return CGRect(x: window.frame.minX + r.minX, y: window.frame.maxY - r.maxY, width: r.width, height: r.height).contains(mouse)
        }
        let now = ProcessInfo.processInfo.systemUptime
        var active = inside
        if inside, needsDwell, !isHovering, !isEditing, !isAligning {
            if enteredAt == nil { enteredAt = now }
            active = now - (enteredAt ?? now) >= 0.35
        } else if !inside {
            enteredAt = nil
        }
        if active { lastInside = now }
        // Hold the hover state briefly so the pointer can cross the gap between the bar and the subtitles.
        let hovering = active || isEditing || (isHovering && now - lastInside < 0.4)
        if window.ignoresMouseEvents == hovering { window.ignoresMouseEvents = !hovering }
        if isHovering != hovering { isHovering = hovering }
    }
}

/// Transparent layer over the subtitles that handles dragging and the context menu.
struct OverlayDragHandle: NSViewRepresentable {
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void
    var onHide: () -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag; view.onEnd = onEnd; view.onHide = onHide; view.onReset = onReset
    }

    final class HandleView: NSView {
        var onDrag: (CGSize) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onHide: () -> Void = {}
        var onReset: () -> Void = {}
        private var start = NSPoint.zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation }
        override func mouseDragged(with event: NSEvent) {
            let point = NSEvent.mouseLocation
            onDrag(CGSize(width: point.x - start.x, height: start.y - point.y))
        }
        override func mouseUp(with event: NSEvent) { onEnd() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            let hide = NSMenuItem(title: AppLocalization.string("overlay.hide"), action: #selector(hide), keyEquivalent: "")
            let reset = NSMenuItem(title: AppLocalization.string("appearance.window.reset"), action: #selector(reset), keyEquivalent: "")
            let lock = NSMenuItem(title: AppLocalization.string("overlay.lock"), action: #selector(lockOverlay), keyEquivalent: "")
            lock.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
            lock.target = self
            let appearance = NSMenuItem(title: AppLocalization.string("overlay.openAppearance"), action: #selector(openAppearance), keyEquivalent: "")
            appearance.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
            hide.target = self; reset.target = self; appearance.target = self
            menu.addItem(appearance)
            menu.addItem(lock)
            menu.addItem(.separator())
            menu.addItem(reset)
            menu.addItem(hide)
            return menu
        }
        @objc private func openAppearance() {
            AppDelegate.shared?.showControlCenter(page: "appearance")
        }
        @objc private func lockOverlay() { OverlayController.setLocked(true) }
        @objc private func hide() { onHide() }
        @objc private func reset() { onReset() }
    }
}
