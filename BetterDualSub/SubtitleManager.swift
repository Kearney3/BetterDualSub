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
@MainActor
class SubtitleManager: ObservableObject, SubtitleTranslationTarget {
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
    /// Set when the subtitles were extracted from a package, whose other tracks can then replace them.
    @Published private(set) var packageTracks: PackageTrackChoice?
    @Published private(set) var switchingTracks = false
    @Published private(set) var trackSwitchError: String?
    private var trackSwitchTask: Task<Void, Never>?
    private var currentSession: ViewingSession?
    private var previousSecondary: (document: SubtitleDocument?, name: String?, trackID: String?, offset: Int, linked: Bool)?
    private let sessionStore = ViewingSessionStore(url: URL.applicationSupportDirectory
        .appendingPathComponent("BetterDualSub/RecentWatching.json"))
    private var sessionSaveTask: Task<Void, Never>?
    private var historyWriteTask: Task<Void, Never>?
    private var historyRestoreTask: Task<Void, Never>?
    private var historyRestoreID = UUID()
    private var preferenceObserver: AnyCancellable?
    private var diagnosticEvents: [[String: String]] = []
    /// Brief confirmation shown over the subtitles after an offset change.
    @Published var delayToast: String?
    private var toastTask: Task<Void, Never>?
    /// Pending "playback lost" notice; brief gaps (between episodes, a seek) cancel it.
    private var lossTask: Task<Void, Never>?
    private var primary: SubtitleDocument?
    private var secondary: SubtitleDocument?
    /// The followed player's clock (called the TV clock, as Apple TV is the default player).
    private let playback = PlaybackCoordinator(client: MediaRemotePlaybackClient(), target: SyncTarget.current, mode: SyncMode.current)
    private let timingStore = SubtitleTimingStore(defaults: .standard)
    /// Title the timing is saved under, once loading has restored it.
    private var timingTitle: String?
    private var internalTimer: Timer?
    private var subtitleTimerInterval: TimeInterval?
    private var appNapActivityToken: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

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
        preferenceObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateSub(); self?.queueSessionSave() }
        Task {
            do { recentSessions = try await sessionStore.load() }
            catch { historyError = error.localizedDescription }
        }
    }

    func reconnect() { playback.start() }

    private func refreshNowPlaying() { playback.refresh() }

    /// Follows `app` from now on (offered when another player is the one playing).
    func follow(_ app: SyncApp) {
        SyncTarget.remember(app)
        UserDefaults.standard.set(app.id, forKey: SyncTarget.key)
        syncTargetDidChange()
    }

    private func refreshSubtitleTimer() {
        let interval: TimeInterval? = isPlaying && !trackNames.isEmpty ? (OverlayController.isVisible ? 0.1 : 1) : nil
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
        if abs(positionMs - position) >= 100 || !playing && positionMs != position || (position == 0) != (positionMs == 0) { positionMs = position }
        let formatted = String(format: "%02d:%02d:%02d", position / 3_600_000, position / 60_000 % 60, position / 1000 % 60)
        if debugTimeStr != formatted { debugTimeStr = formatted }
        // The video position already runs at the player's speed, so the subtitles follow it 1:1, minus the delay.
        let first = primary?.text(at: position - timeOffsetMs) ?? ""
        let second = secondary?.text(at: position - secondaryOffsetMs) ?? ""
        if currentText != first { currentText = first }
        if secondaryText != second { secondaryText = second }
        refreshSyncStatus()
        refreshSubtitleTimer()
    }

    // MARK: Playback controls (manual clock, or the followed player through Now Playing commands)

    /// Cues of a track ("primary" / "secondary") for the alignment picker.
    func cues(track: String) -> [SubtitleItem] { (track == "secondary" ? secondary : primary)?.items ?? [] }

    /// Current playback position in ms, before any subtitle delay.
    func currentPositionMs() -> Int {
        playback.positionMs
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
        previousSecondary = (secondary, trackNames.count > 1 ? trackNames[1] : nil, packageTracks?.secondaryID,
                             secondaryOffsetMs, linkSecondaryDelay)
        canUndoSecondary = true
        packageTracks?.secondaryID = nil
        secondary = document
        currentSession?.secondarySRT = document.srt
        trackNames = [trackNames[0], name]
        durationMs = max(durationMs, documentDurationMs)
        secondaryOffsetMs = timeOffsetMs
        updateSub()
        queueSessionSave()
    }

    func undoSecondary() {
        guard let previousSecondary else { return }
        secondary = previousSecondary.document
        currentSession?.secondarySRT = secondary?.srt
        trackNames = [trackNames[0]] + (previousSecondary.name.map { [$0] } ?? [])
        packageTracks?.secondaryID = previousSecondary.trackID
        linkSecondaryDelay = previousSecondary.linked
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
        var loaded: [String: SubtitleDocument] = [:]
        loaded[oldPrimary] = primary
        if let oldSecondary, !oldSecondary.isEmpty { loaded[oldSecondary] = secondary }
        let missing = choice.tracks.filter { [primaryID, secondaryID].contains($0.id) && loaded[$0.id] == nil }
        let packageTimeline = choice.packageTimeline, initialLoad = loadID, current = loaded
        switchingTracks = true
        trackSwitchError = nil
        trackSwitchTask = Task {
            do {
                let extracted = try await SubtitleBackgroundWork.run {
                    try missing.map { ($0.id, try MovpkgSubtitleExtractor.document(for: $0, packageTimeline: packageTimeline)) }
                }
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
        if !hadSecondary && secondary != nil { secondaryOffsetMs = timeOffsetMs }
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
            "listenerAlive": playback.connection == .connected, "mode": SyncMode.current.rawValue, "target": SyncTarget.current,
            "following": syncStatus.isFollowing, "playing": isPlaying, "positionMs": currentPositionMs(),
            "rate": playbackSpeed, "primaryCueCount": primary?.items.count ?? 0, "secondaryCueCount": secondary?.items.count ?? 0,
            "primaryOffsetMs": timeOffsetMs, "secondaryOffsetMs": secondaryOffsetMs, "health": subtitleHealthKey,
            "events": diagnosticEvents]
        if let lastReportUptime = playback.lastReportUptime {
            snapshot["lastReportAgeSeconds"] = max(0, ProcessInfo.processInfo.systemUptime - lastReportUptime)
        }
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

