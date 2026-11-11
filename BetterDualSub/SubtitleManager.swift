import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import Foundation

/// Where the playback position comes from.
extension SyncMode {
    static let storageKey = "syncMode"
    static var current: SyncMode { SyncMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto }
}

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
        case .connecting: AppLocalization.string("sync.status.connecting")
        case .disconnected: AppLocalization.string("sync.status.disconnected")
        }
    }

    /// What the user can do about it, if anything.
    var help: String? {
        switch self {
        case .manual: AppLocalization.string("sync.status.manual.help")
        case .following: nil
        case .connecting: AppLocalization.string("sync.status.connecting.help")
        case .waiting(let other?): AppLocalization.format("sync.status.otherApp.help", other.name, SyncTarget.currentName)
        case .waiting(nil): AppLocalization.format("sync.status.waiting.help", SyncTarget.currentName)
        case .disconnected: AppLocalization.string("sync.status.disconnected.help")
        }
    }
}

// Both subtitle tracks are driven by one clock: the Apple TV playback clock, or a manual one when TV is unavailable.
@MainActor @Observable
final class SubtitleManager: SubtitleTranslationTarget {
    /// Shared with the overlay panel, which lives outside the SwiftUI scene graph.
    static let shared = SubtitleManager()
    static let manualSpeeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    var currentText = ""
    var secondaryText = ""
    var isPlaying = false
    var timeOffsetMs = 0 {
        didSet {
            let bounded = max(-86_400_000, min(86_400_000, timeOffsetMs))
            // Assigning inside the observer runs it again with the bounded value, which does the rest.
            if timeOffsetMs != bounded { timeOffsetMs = bounded; return }
            if linkSecondaryDelay && secondaryOffsetMs != timeOffsetMs { secondaryOffsetMs = timeOffsetMs }
            saveOffsets()
            updateSub()
        }
    }
    var secondaryOffsetMs = 0 {
        didSet {
            let bounded = max(-86_400_000, min(86_400_000, secondaryOffsetMs))
            if secondaryOffsetMs != bounded { secondaryOffsetMs = bounded; return }
            if linkSecondaryDelay && timeOffsetMs != secondaryOffsetMs { timeOffsetMs = secondaryOffsetMs }
            saveOffsets()
            updateSub()
        }
    }
    /// Drift correction of each track (`SubtitleDrift`): 1 runs the file 1:1 with the video. Changed only by
    /// `correctDrift` and `resetDrift`, never by a delay, and linked like the delays.
    private(set) var primaryScale = 1.0
    private(set) var secondaryScale = 1.0
    /// The last line aligned on each track, as the first point for `correctDrift`.
    private(set) var driftAnchors: [String: SubtitleDrift.Point] = [:]
    /// The timing saved for this title was restored when it was loaded.
    private(set) var restoredTiming = false
    /// While on, Track B always has the same delay as Track A (changing either changes both). Persisted by `setLink`.
    var linkSecondaryDelay = UserDefaults.standard.object(forKey: "linkSecondaryDelay") as? Bool ?? true
    var debugTimeStr = "00:00"
    var loadedTitle = ""
    var trackNames: [String] = []
    /// Playback position (without subtitle offsets) and timeline length, for the manual progress bar.
    var positionMs = 0
    var durationMs = 0
    var activeSource: SyncSource = .manual
    var manualSpeed = 1.0
    var manualPlaying = false
    /// Name of the app whose clock is currently followed, if any.
    var syncedAppName: String?
    private(set) var syncStatus: SyncStatus = .waiting(otherApp: nil)
    /// Speed the subtitles run at: the followed player's playback speed, or the manual clock's.
    private(set) var playbackSpeed = 1.0
    /// Changes on every load, so work started for one set of subtitles is not applied to the next.
    private(set) var loadID = UUID()
    private(set) var recentSessions: [ViewingSession] = []
    private(set) var historyError: String?
    private(set) var canUndoSecondary = false
    /// Set when the subtitles were extracted from a package, whose other tracks can then replace them.
    private(set) var packageTracks: PackageTrackChoice?
    private(set) var switchingTracks = false
    private(set) var trackSwitchError: String?
    @ObservationIgnored private var trackSwitchTask: Task<Void, Never>?
    @ObservationIgnored private var currentSession: ViewingSession?
    @ObservationIgnored private var previousSecondary: (document: SubtitleDocument?, name: String?, trackID: String?, offset: Int, scale: Double, linked: Bool)?
    @ObservationIgnored private let sessionStore = ViewingSessionStore(url: URL.applicationSupportDirectory
        .appendingPathComponent("BetterDualSub/RecentWatching.json"))
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var historyWriteTask: Task<Void, Never>?
    @ObservationIgnored private var historyRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var historyRestoreID = UUID()
    /// What `preferenceSnapshot` returned when the display was last brought up to date.
    @ObservationIgnored private var observedPreferences = PreferenceSnapshot()
    @ObservationIgnored private var preferenceObserver: AnyCancellable?
    @ObservationIgnored private var diagnosticEvents: [[String: String]] = []
    /// Brief confirmation shown over the subtitles after an offset change.
    var delayToast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Pending "playback lost" notice; brief gaps (between episodes, a seek) cancel it.
    @ObservationIgnored private var lossTask: Task<Void, Never>?
    private var primary: SubtitleDocument? { didSet { shownSecondaryCache = nil } }
    private var secondary: SubtitleDocument? { didSet { shownSecondaryCache = nil } }
    /// Track 2 as shown, for the delay difference and tolerance it was snapped with (`shownSecondary`).
    @ObservationIgnored private var shownSecondaryCache: (shiftMs: Int, tolerance: Int, document: SubtitleDocument?)?

    /// Position in a track's own file time: the video position less the delay, over the drift correction.
    func fileTimeMs(track: String, atVideo videoMs: Int? = nil) -> Int {
        let secondaryTrack = track == "secondary"
        return SubtitleDrift.fileTime(atVideo: videoMs ?? playback.positionMs, offsetMs: secondaryTrack ? secondaryOffsetMs : timeOffsetMs,
                                      scale: secondaryTrack ? secondaryScale : primaryScale)
    }

    private func videoTimeMs(track: String, ofFile fileMs: Int) -> Int {
        let secondaryTrack = track == "secondary"
        return SubtitleDrift.videoTime(ofFile: fileMs, offsetMs: secondaryTrack ? secondaryOffsetMs : timeOffsetMs,
                                       scale: secondaryTrack ? secondaryScale : primaryScale)
    }
    /// Two subtitle files of one video rarely end their lines at exactly the same moment; differences up to this
    /// setting (0 turns it off) are treated as the same moment, so neither track's line lingers after the other's.
    static let trackSnapToleranceKey = "trackSnapToleranceMs"
    static let defaultTrackSnapToleranceMs = 500
    static let trackSnapTolerances = 0...2000
    static var trackSnapToleranceMs: Int {
        let value = UserDefaults.standard.object(forKey: trackSnapToleranceKey) as? Int ?? defaultTrackSnapToleranceMs
        return min(max(value, trackSnapTolerances.lowerBound), trackSnapTolerances.upperBound)
    }
    /// The followed player's clock (called the TV clock, as Apple TV is the default player).
    @ObservationIgnored private let playback = PlaybackCoordinator(client: MediaRemotePlaybackClient(), target: SyncTarget.current, mode: SyncMode.current)
    @ObservationIgnored private let timingStore = SubtitleTimingStore(defaults: .standard)
    /// Title the timing is saved under, once loading has restored it.
    @ObservationIgnored private var timingTitle: String?
    @ObservationIgnored private var internalTimer: Timer?
    @ObservationIgnored private var subtitleTimerInterval: TimeInterval?
    /// Fires at the next cue start or end, so lines change on time instead of on the next periodic tick.
    @ObservationIgnored private var cueTimer: Timer?
    @ObservationIgnored private var cueFireUptime: TimeInterval?
    @ObservationIgnored private var appNapActivityToken: NSObjectProtocol?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        playback.onChange = { [weak self] in
            guard let self else { return }
            if let app = self.playback.reportedApp { SyncTarget.remember(app) }
            self.recordDiagnostic(self.playback.event)
            self.updateSub()
        }
        playback.start()
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playback.suspend() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playback.start() }
        })
        // Any preference write posts this notification, delays and window moves included; only a change in what the
        // subtitles are built from (below) is worth redoing the display and the history snapshot for.
        observedPreferences = Self.preferenceSnapshot()
        preferenceObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let snapshot = Self.preferenceSnapshot()
                guard snapshot != self.observedPreferences else { return }
                self.observedPreferences = snapshot
                self.updateSub()
                self.queueSessionSave()
            }
        Task {
            do { recentSessions = try await sessionStore.load() }
            catch { historyError = error.localizedDescription }
        }
    }

    /// The preferences the display and the saved history depend on: whether the overlay is shown, the snap tolerance
    /// and the appearance saved with a session.
    private struct PreferenceSnapshot: Equatable {
        var overlayVisible = true
        var snapToleranceMs = SubtitleManager.defaultTrackSnapToleranceMs
        var appearance: NSDictionary = [:]
    }

    private static func preferenceSnapshot() -> PreferenceSnapshot {
        let keys = Set(ViewingDisplaySettings.keys)
        return PreferenceSnapshot(
            overlayVisible: OverlayController.isVisible, snapToleranceMs: trackSnapToleranceMs,
            appearance: UserDefaults.standard.dictionaryRepresentation().filter { keys.contains($0.key) } as NSDictionary)
    }

    func reconnect() { playback.start() }

    private func refreshNowPlaying() { playback.refresh() }

    /// Follows `app` from now on (offered when another player is the one playing).
    func follow(_ app: SyncApp) {
        SyncTarget.remember(app)
        UserDefaults.standard.set(app.id, forKey: SyncTarget.key)
        syncTargetDidChange()
    }

    /// The periodic timer only keeps the position readouts moving; cue changes have their own timer.
    private func refreshSubtitleTimer() {
        let interval: TimeInterval? = isPlaying && !trackNames.isEmpty ? (OverlayController.isVisible ? 0.25 : 1) : nil
        guard subtitleTimerInterval != interval else { return }
        internalTimer?.invalidate()
        internalTimer = nil
        subtitleTimerInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSub() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        internalTimer = timer
    }

    /// Schedules an update for the moment either track's text next changes, at the current playback speed.
    private func scheduleCueTimer(position: Int) {
        let speed = playbackSpeed
        // A scaled boundary can round to the current position; the timer then fires at once and moves past it.
        let next = [primary?.nextChange(after: fileTimeMs(track: "primary", atVideo: position)).map { videoTimeMs(track: "primary", ofFile: $0) },
                    shownSecondary()?.nextChange(after: fileTimeMs(track: "secondary", atVideo: position))
                        .map { videoTimeMs(track: "secondary", ofFile: $0) }]
            .compactMap { $0 }.map { max($0, position + 1) }.min()
        guard isPlaying, OverlayController.isVisible, speed > 0, let next else {
            cueTimer?.invalidate()
            cueTimer = nil
            cueFireUptime = nil
            return
        }
        // A couple of milliseconds late, so the clock has reached the boundary when the timer fires.
        let fire = ProcessInfo.processInfo.systemUptime + Double(next - position) / 1000 / speed + 0.002
        if let cueFireUptime, cueTimer?.isValid == true, abs(cueFireUptime - fire) < 0.004 { return }
        cueTimer?.invalidate()
        cueFireUptime = fire
        let timer = Timer(timeInterval: max(0, fire - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cueFireUptime = nil
                self?.updateSub()
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        cueTimer = timer
    }

    func syncTargetDidChange() { playback.setTarget(SyncTarget.current) }

    private func refreshSyncStatus() {
        if playbackSpeed != playback.playbackSpeed { playbackSpeed = playback.playbackSpeed }
        let status = playback.status
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
        durationMs = max(documentDurationMs, playback.tracker.durationMs ?? 0)
        playback.tick(durationMs: durationMs)
        let position = playback.positionMs
        let playing = playback.isPlaying
        if activeSource != playback.activeSource { activeSource = playback.activeSource }
        if manualPlaying != playback.manualPlaying { manualPlaying = playback.manualPlaying }
        if manualSpeed != playback.manualSpeed { manualSpeed = playback.manualSpeed }
        let appName = activeSource == .tv ? playback.tracker.followedApp?.name : nil
        if syncedAppName != appName { syncedAppName = appName }
        if isPlaying != playing { isPlaying = playing }
        if playing && !trackNames.isEmpty && OverlayController.isVisible {
            if appNapActivityToken == nil {
                appNapActivityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated], reason: "Synchronize subtitles with playback."
                )
            }
        } else if let token = appNapActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            appNapActivityToken = nil
        }
        if abs(positionMs - position) >= 200 || !playing && positionMs != position || (position == 0) != (positionMs == 0) { positionMs = position }
        let formatted = String(format: "%02d:%02d:%02d", position / 3_600_000, position / 60_000 % 60, position / 1000 % 60)
        if debugTimeStr != formatted { debugTimeStr = formatted }
        // The video position already runs at the player's speed, so the subtitles follow it 1:1, minus the delay
        // (and over the drift correction, for a file made for another frame rate).
        let first = primary?.text(at: fileTimeMs(track: "primary", atVideo: position)) ?? ""
        let second = shownSecondary()?.text(at: fileTimeMs(track: "secondary", atVideo: position)) ?? ""
        if currentText != first { currentText = first }
        if secondaryText != second { secondaryText = second }
        refreshSyncStatus()
        refreshSubtitleTimer()
        scheduleCueTimer(position: position)
    }

    /// Track 2 with its cue starts and ends snapped to nearby ones of Track 1, as they line up on screen with the
    /// current delays. Only what is shown changes: alignment, export and history keep Track 2's own timing.
    private func shownSecondary() -> SubtitleDocument? {
        // Tracks with different drift corrections are not a constant shift apart, so there is nothing to snap to.
        guard let secondary, let primary, primaryScale == secondaryScale else { return secondary }
        let shift = Int((Double(timeOffsetMs - secondaryOffsetMs) / primaryScale).rounded()), tolerance = Self.trackSnapToleranceMs
        if let cache = shownSecondaryCache, cache.shiftMs == shift, cache.tolerance == tolerance { return cache.document }
        let shown = secondary.snapped(to: primary, shiftMs: shift, tolerance: tolerance)
        shownSecondaryCache = (shift, tolerance, shown)
        return shown
    }

    // MARK: Playback controls (manual clock, or the followed player through Now Playing commands)

    /// Cues of a track ("primary" / "secondary") for the alignment picker.
    func cues(track: String) -> [SubtitleItem] { (track == "secondary" ? secondary : primary)?.items ?? [] }

    /// Current playback position in ms, before any subtitle delay.
    func currentPositionMs() -> Int {
        playback.positionMs
    }

    /// Times `track` so that `cue` is the line on screen right now (cue at 8:00 while playing at 10:00 -> +2:00).
    /// Returns the new delay. Only the delay changes; a drift correction, if any, is kept. The line is remembered as
    /// the first point for `correctDrift`.
    @discardableResult
    func align(track: String, to cue: SubtitleItem) -> Int {
        let point = SubtitleDrift.Point(fileMs: cue.startMs, videoMs: currentPositionMs())
        setDelay(track: track, ms: SubtitleDrift.offset(for: point, scale: track == "secondary" ? secondaryScale : primaryScale))
        driftAnchors[track] = point
        return track == "secondary" ? secondaryOffsetMs : timeOffsetMs
    }

    /// Fits `track` to the line aligned before and to `cue` being the line on screen right now, which corrects a file
    /// made for another frame rate. Asked for explicitly; nothing else changes the scale. With linked tracks both
    /// get it. Without an earlier `align`, or when the lines do not give a usable fit, nothing changes.
    func correctDrift(track: String, to cue: SubtitleItem) -> SubtitleDrift.Fit? {
        guard let anchor = driftAnchors[track] else { return nil }
        let fit = SubtitleDrift.fit(anchor, SubtitleDrift.Point(fileMs: cue.startMs, videoMs: currentPositionMs()))
        guard case .fitted(let scale, let offsetMs) = fit else { return fit }
        setScale(track: track, scale)
        if track == "secondary" { secondaryOffsetMs = offsetMs } else { timeOffsetMs = offsetMs }
        saveOffsets()
        updateSub()
        showToast(timingSummary)
        return fit
    }

    /// Back to 1:1 with the video, keeping the line that is on screen now where it is.
    func resetDrift(track: String) {
        let position = currentPositionMs()
        let point = SubtitleDrift.Point(fileMs: fileTimeMs(track: track, atVideo: position), videoMs: position)
        setScale(track: track, 1)
        driftAnchors[track] = nil
        if track == "secondary" { secondaryOffsetMs = point.videoMs - point.fileMs } else { timeOffsetMs = point.videoMs - point.fileMs }
        saveOffsets()
        updateSub()
        showToast(timingSummary)
    }

    private func setScale(track: String, _ scale: Double) {
        if track == "secondary" || linkSecondaryDelay { secondaryScale = scale }
        if track != "secondary" || linkSecondaryDelay { primaryScale = scale }
        shownSecondaryCache = nil
    }

    private var documentDurationMs: Int {
        max(primary?.duration ?? 0, secondary?.duration ?? 0)
    }

    func togglePlay() { playback.togglePlay(durationMs: durationMs) }

    func seek(toMs target: Int) { playback.seek(toMs: target, durationMs: durationMs) }

    func seek(byMs delta: Int) { seek(toMs: playback.positionMs + delta) }

    func toggleManualPlay() { playback.togglePlay(durationMs: durationMs) }

    func seekManual(toMs target: Int) { playback.seek(toMs: target, durationMs: durationMs) }

    func seekManual(byMs delta: Int) { seek(byMs: delta) }

    func setManualSpeed(_ speed: Double) { playback.setManualSpeed(speed) }

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
        playback.setMode(mode)
    }

    // MARK: Loading and offsets

    func load(primary: SubtitleDocument, secondary: SubtitleDocument? = nil, title: String, names: [String],
              sourceID: String = "file", restoring: ViewingSession? = nil, packageTracks: PackageTrackChoice? = nil) {
        historyRestoreTask?.cancel()
        trackSwitchTask?.cancel()
        switchingTracks = false
        trackSwitchError = nil
        self.packageTracks = packageTracks
        historyRestoreID = UUID()
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
        self.primary = primary
        self.secondary = secondary
        loadID = UUID()
        loadedTitle = title
        trackNames = names
        currentText = ""
        secondaryText = ""
        durationMs = documentDurationMs
        playback.resetManualClock()
        timingTitle = nil
        let timingKey = "session." + session.id
        let saved = restoring?.timing ?? timingStore.load(sessionID: session.id, legacyTitle: title)
        timeOffsetMs = saved.primaryOffsetMs
        secondaryOffsetMs = linkSecondaryDelay ? saved.primaryOffsetMs : saved.secondaryOffsetMs
        primaryScale = saved.primaryScale
        secondaryScale = linkSecondaryDelay ? saved.primaryScale : saved.secondaryScale
        driftAnchors = [:]
        timingTitle = timingKey
        currentSession = session
        restoredTiming = timeOffsetMs != 0 || secondaryOffsetMs != 0 || primaryScale != 1 || secondaryScale != 1
        // Loading subtitles means the user wants to see them, even if the window was hidden earlier.
        if !OverlayController.isVisible { OverlayController.setVisible(true) }
        updateSub()
        if !UserDefaults.standard.bool(forKey: ViewingGuide.overlayTipShownKey) {
            // The overlay's controls only appear on hover; say so once, where the subtitles are.
            UserDefaults.standard.set(true, forKey: ViewingGuide.overlayTipShownKey)
            showToast(AppLocalization.string("overlay.tip.firstLoad"), seconds: 7)
        } else if restoredTiming {
            showToast(AppLocalization.format("timing.restored.toast", timingSummary), seconds: 3)
        }
        recordDiagnostic(restoring == nil ? "loaded" : "restored")
        queueSessionSave()
    }

    /// Delay of each track, such as "+1200 ms" or, for different tracks, both joined by " / ".
    var timingSummary: String {
        func summary(_ offset: Int, _ scale: Double) -> String {
            String(format: "%+d ms", offset) + (scale == 1 ? "" : " " + Self.scaleLabel(scale))
        }
        let first = summary(timeOffsetMs, primaryScale)
        guard secondary != nil, secondaryOffsetMs != timeOffsetMs || secondaryScale != primaryScale else { return first }
        return first + " / " + summary(secondaryOffsetMs, secondaryScale)
    }

    /// A drift correction as shown to the user, such as "×1.0427".
    static func scaleLabel(_ scale: Double) -> String { String(format: "×%.4f", scale) }

    /// The loaded Track 1, as the source for a translated Track 2.
    var primaryDocument: SubtitleDocument? { primary }

    /// Replaces Track 2 with `document`, which is timed within Track 1's cues (a translation of it), so it also takes
    /// Track 1's delay.
    func setSecondary(_ document: SubtitleDocument, name: String) {
        guard !trackNames.isEmpty else { return }
        previousSecondary = (secondary, trackNames.count > 1 ? trackNames[1] : nil, packageTracks?.secondaryID,
                             secondaryOffsetMs, secondaryScale, linkSecondaryDelay)
        canUndoSecondary = true
        packageTracks?.secondaryID = nil
        secondary = document
        currentSession?.secondarySRT = document.srt
        trackNames = [trackNames[0], name]
        durationMs = max(durationMs, documentDurationMs)
        secondaryScale = primaryScale
        driftAnchors["secondary"] = nil
        secondaryOffsetMs = timeOffsetMs
        updateSub()
        queueSessionSave()
    }

    /// Replaces the translated Track 2 that `setSecondary` set with more of it, keeping its delay and the undo.
    func updateSecondary(_ document: SubtitleDocument) {
        guard canUndoSecondary, !trackNames.isEmpty else { return }
        secondary = document
        currentSession?.secondarySRT = document.srt
        durationMs = max(durationMs, documentDurationMs)
        updateSub()
        queueSessionSave()
    }

    /// Track 1's position in its own time, where a translation of it should start.
    var translationPositionMs: Int { fileTimeMs(track: "primary") }

    func undoSecondary() {
        guard let previousSecondary else { return }
        secondary = previousSecondary.document
        currentSession?.secondarySRT = secondary?.srt
        trackNames = [trackNames[0]] + (previousSecondary.name.map { [$0] } ?? [])
        packageTracks?.secondaryID = previousSecondary.trackID
        linkSecondaryDelay = previousSecondary.linked
        secondaryScale = previousSecondary.scale
        driftAnchors["secondary"] = nil
        secondaryOffsetMs = previousSecondary.offset
        self.previousSecondary = nil
        canUndoSecondary = false
        durationMs = max(documentDurationMs, playback.tracker.durationMs ?? 0)
        updateSub()
        queueSessionSave()
    }

    /// Replaces Track 1 and/or Track 2 (nil keeps it, "" removes Track 2) with other tracks of the same package for
    /// this viewing only: the language preferences used by the next import stay as they are. The tracks share the
    /// package's timeline, so the delays are kept; choosing the other track's subtitles swaps the two.
    func switchPackageTracks(primaryID newPrimary: String? = nil, secondaryID newSecondary: String? = nil) {
        guard let choice = packageTracks, !switchingTracks,
              newSecondary.map({ $0.isEmpty || choice.label($0) != nil }) ?? true else { return }
        let oldPrimary = choice.primaryID, oldSecondary = choice.secondaryID
        var primaryID = newPrimary ?? oldPrimary, secondaryID = newSecondary ?? oldSecondary
        if primaryID == secondaryID {
            guard let oldSecondary, !oldSecondary.isEmpty else { return }
            if newPrimary != nil { secondaryID = oldPrimary } else { primaryID = oldSecondary }
        }
        guard primaryID != oldPrimary || secondaryID != oldSecondary, choice.label(primaryID) != nil else { return }
        var loaded = choice.documents
        loaded[oldPrimary] = primary
        if let oldSecondary, !oldSecondary.isEmpty { loaded[oldSecondary] = secondary }
        let missing = choice.tracks.filter { [primaryID, secondaryID].contains($0.id) && loaded[$0.id] == nil }
        let packageTimeline = choice.packageTimeline, initialLoad = loadID, current = loaded
        switchingTracks = true
        trackSwitchError = nil
        trackSwitchTask = Task {
            do {
                let extracted = try await LocalSubtitleExtractor.documents(for: missing, packageTimeline: packageTimeline)
                guard !Task.isCancelled, loadID == initialLoad else { return }
                let documents = current.merging(extracted) { $1 }
                guard let first = documents[primaryID] else { return }
                applyPackageTracks(choice, primaryID: primaryID, secondaryID: secondaryID, first: first,
                                   second: secondaryID.flatMap { documents[$0] })
            } catch {
                guard !Task.isCancelled, loadID == initialLoad else { return }
                trackSwitchError = error.localizedDescription
            }
            switchingTracks = false
        }
    }

    private func applyPackageTracks(_ choice: PackageTrackChoice, primaryID: String, secondaryID: String?,
                                    first: SubtitleDocument, second: SubtitleDocument?) {
        SubtitleTranslator.shared.cancel()
        // Work started for the replaced subtitles (a translation, an alignment pick) no longer applies.
        loadID = UUID()
        let hadSecondary = secondary != nil
        primary = first
        var names = [choice.label(primaryID) ?? trackNames[0]]
        if secondaryID == choice.secondaryID {
            names += trackNames.dropFirst()
        } else {
            secondary = second
            if let secondaryID, let name = choice.label(secondaryID) { names.append(name) }
            previousSecondary = nil
            canUndoSecondary = false
        }
        packageTracks?.primaryID = primaryID
        packageTracks?.secondaryID = secondaryID
        trackNames = names
        currentSession?.primarySRT = first.srt
        currentSession?.secondarySRT = secondary?.srt
        // A new Track 2 starts on Track 1's delay; existing delays stay exactly as they were.
        if !hadSecondary && secondary != nil { secondaryScale = primaryScale; secondaryOffsetMs = timeOffsetMs }
        driftAnchors = [:]
        currentText = ""
        secondaryText = ""
        updateSub()
        showToast(AppLocalization.format("nowPlaying.tracks.switched", timingSummary))
        queueSessionSave()
    }

    func restoreSession(_ session: ViewingSession) {
        historyRestoreTask?.cancel()
        let token = UUID(), initialLoad = loadID
        historyRestoreID = token
        historyRestoreTask = Task {
            do {
                let (first, second) = try await SubtitleBackgroundWork.run {
                    let first = try SubtitleDocument(text: session.primarySRT)
                    let second = try session.secondarySRT.map { try SubtitleDocument(text: $0) }
                    guard session.names.count == (second == nil ? 1 : 2) else { throw SubtitleError.message("error.history.invalid") }
                    return (first, second)
                }
                guard !Task.isCancelled, historyRestoreID == token, loadID == initialLoad else { return }
                load(primary: first, secondary: second, title: session.title, names: session.names, restoring: session)
                refreshNowPlaying()
                showControlCenterPage("nowPlaying")
            } catch {
                guard !Task.isCancelled, historyRestoreID == token else { return }
                historyError = error.localizedDescription
            }
        }
    }

    func removeSession(id: String?) {
        historyRestoreTask?.cancel()
        historyRestoreID = UUID()
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
        guard var session = currentSession else { return nil }
        SubtitleScreenPreferences.saveCurrentLayout()
        session.names = trackNames
        session.timing = currentTiming
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
        let start = min(videoTimeMs(track: "primary", ofFile: primary.items.first?.startMs ?? 0),
                        secondary.map { videoTimeMs(track: "secondary", ofFile: $0.items.first?.startMs ?? 0) } ?? Int.max)
        let end = max(videoTimeMs(track: "primary", ofFile: primary.duration),
                      secondary.map { videoTimeMs(track: "secondary", ofFile: $0.duration) } ?? Int.min)
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
            "listenerAlive": playback.connection == .connected, "mode": SyncMode.current.rawValue, "target": SyncTarget.current,
            "following": syncStatus.isFollowing, "playing": isPlaying, "positionMs": currentPositionMs(),
            "rate": playbackSpeed, "primaryCueCount": primary?.items.count ?? 0, "secondaryCueCount": secondary?.items.count ?? 0,
            "primaryOffsetMs": timeOffsetMs, "secondaryOffsetMs": secondaryOffsetMs, "primaryScale": primaryScale,
            "secondaryScale": secondaryScale, "health": subtitleHealthKey,
            "events": diagnosticEvents]
        if let lastReportUptime = playback.lastReportUptime {
            snapshot["lastReportAgeSeconds"] = max(0, ProcessInfo.processInfo.systemUptime - lastReportUptime)
        }
        do { try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }

    private func saveOffsets() {
        guard let title = timingTitle else { return }
        timingStore.save(currentTiming, title: title)
        queueSessionSave()
    }

    private var currentTiming: SavedTiming {
        SavedTiming(primaryOffsetMs: timeOffsetMs, secondaryOffsetMs: secondaryOffsetMs, primaryScale: primaryScale, secondaryScale: secondaryScale)
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
        if on { secondaryScale = primaryScale; shownSecondaryCache = nil; secondaryOffsetMs = timeOffsetMs }
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

