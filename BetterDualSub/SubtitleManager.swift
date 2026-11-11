import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import Foundation

// Both subtitle tracks are driven by one clock: the Apple TV playback clock, or a manual one when TV is unavailable.
@MainActor @Observable
final class SubtitleManager: SubtitleTranslationTarget {
    /// Shared with the overlay panel, which lives outside the SwiftUI scene graph.
    static let shared = SubtitleManager()
    static let manualSpeeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    var currentText = ""
    var secondaryText = ""
    var isPlaying = false
    /// Delays, drift corrections and the track link. Changing it saves the timing and brings the display up to date.
    private(set) var timing = DualTrackTiming(linked: UserDefaults.standard.object(forKey: "linkSecondaryDelay") as? Bool ?? true) {
        didSet {
            guard timing != oldValue else { return }
            if timing.saved != oldValue.saved { saveOffsets() } else if timing.linked != oldValue.linked { queueSessionSave() }
            updateSub()
        }
    }
    var timeOffsetMs: Int {
        get { timing.primaryOffsetMs }
        set { timing.setDelay(.primary, ms: newValue) }
    }
    var secondaryOffsetMs: Int {
        get { timing.secondaryOffsetMs }
        set { timing.setDelay(.secondary, ms: newValue) }
    }
    /// While on, Track B always has the same delay as Track A (changing either changes both). Persisted by `setLink`.
    var linkSecondaryDelay: Bool { timing.linked }
    /// The timing saved for this title was restored when it was loaded.
    private(set) var restoredTiming = false
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
    private(set) var canUndoSecondary = false
    /// Set when the subtitles were extracted from a package, whose other tracks can then replace them.
    private(set) var packageTracks: PackageTrackChoice?
    private(set) var switchingTracks = false
    private(set) var trackSwitchError: String?
    @ObservationIgnored private var trackSwitchTask: Task<Void, Never>?
    @ObservationIgnored private var currentSession: ViewingSession?
    @ObservationIgnored private var previousSecondary: (document: SubtitleDocument?, name: String?, trackID: String?, timing: DualTrackTiming.SecondarySnapshot)?
    /// The recent sessions on disk; the interface reads them through `recentSessions` and `historyError`.
    let history = ViewingHistory(store: ViewingSessionStore(url: URL.applicationSupportDirectory
        .appendingPathComponent("BetterDualSub/RecentWatching")))
    var recentSessions: [ViewingSession] { history.sessions }
    var historyError: String? { history.error }
    @ObservationIgnored private var historyRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var historyRestoreID = UUID()
    /// What `preferenceSnapshot` returned when the display was last brought up to date.
    @ObservationIgnored private var observedPreferences = PreferenceSnapshot()
    @ObservationIgnored private var preferenceObserver: AnyCancellable?
    @ObservationIgnored private var diagnosticEvents = DiagnosticEvents()
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
    func fileTimeMs(track: Track, atVideo videoMs: Int? = nil) -> Int {
        timing.fileTimeMs(track, atVideo: videoMs ?? playback.positionMs)
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
    /// The periodic tick, the next-cue timer and the App Nap activity.
    @ObservationIgnored private let timers = SubtitleTimers()
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        playback.onChange = { [weak self] in
            guard let self else { return }
            if let app = self.playback.reportedApp { SyncTarget.remember(app) }
            self.recordDiagnostic(self.playback.event)
            self.updateSub()
        }
        timers.onFire = { [weak self] in self?.updateSub() }
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
        Task { await history.load() }
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
        timers.setPeriodic(interval: isPlaying && !trackNames.isEmpty ? (OverlayController.isVisible ? 0.25 : 1) : nil)
    }

    /// Schedules an update for the moment either track's text next changes, at the current playback speed.
    private func scheduleCueTimer(position: Int) {
        let speed = playbackSpeed
        // A scaled boundary can round to the current position; the timer then fires at once and moves past it.
        let next = [primary?.nextChange(after: timing.fileTimeMs(.primary, atVideo: position)).map { timing.videoTimeMs(.primary, ofFile: $0) },
                    shownSecondary()?.nextChange(after: timing.fileTimeMs(.secondary, atVideo: position))
                        .map { timing.videoTimeMs(.secondary, ofFile: $0) }]
            .compactMap { $0 }.map { max($0, position + 1) }.min()
        guard isPlaying, OverlayController.isVisible, speed > 0, let next else { return timers.scheduleCue(atUptime: nil) }
        // A couple of milliseconds late, so the clock has reached the boundary when the timer fires.
        timers.scheduleCue(atUptime: ProcessInfo.processInfo.systemUptime + Double(next - position) / 1000 / speed + 0.002)
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
        timers.setKeepingAwake(playing && !trackNames.isEmpty && OverlayController.isVisible)
        if abs(positionMs - position) >= 200 || !playing && positionMs != position || (position == 0) != (positionMs == 0) { positionMs = position }
        let formatted = String(format: "%02d:%02d:%02d", position / 3_600_000, position / 60_000 % 60, position / 1000 % 60)
        if debugTimeStr != formatted { debugTimeStr = formatted }
        // The video position already runs at the player's speed, so the subtitles follow it 1:1, minus the delay
        // (and over the drift correction, for a file made for another frame rate).
        let first = primary?.text(at: timing.fileTimeMs(.primary, atVideo: position)) ?? ""
        let second = shownSecondary()?.text(at: timing.fileTimeMs(.secondary, atVideo: position)) ?? ""
        if currentText != first { currentText = first }
        if secondaryText != second { secondaryText = second }
        refreshSyncStatus()
        refreshSubtitleTimer()
        scheduleCueTimer(position: position)
    }

    /// Track 2 with its cue starts and ends snapped to nearby ones of Track 1, as they line up on screen with the
    /// current delays. Only what is shown changes: alignment, export and history keep Track 2's own timing.
    private func shownSecondary() -> SubtitleDocument? {
        guard let secondary, let primary, let shift = timing.snapShiftMs else { return secondary }
        let tolerance = Self.trackSnapToleranceMs
        if let cache = shownSecondaryCache, cache.shiftMs == shift, cache.tolerance == tolerance { return cache.document }
        let shown = secondary.snapped(to: primary, shiftMs: shift, tolerance: tolerance)
        shownSecondaryCache = (shift, tolerance, shown)
        return shown
    }

    // MARK: Playback controls (manual clock, or the followed player through Now Playing commands)

    /// Cues of a track, for the alignment picker.
    func cues(track: Track) -> [SubtitleItem] { (track.isSecondary ? secondary : primary)?.items ?? [] }

    /// Current playback position in ms, before any subtitle delay.
    func currentPositionMs() -> Int {
        playback.positionMs
    }

    /// Times `track` so that `cue` is the line on screen right now (cue at 8:00 while playing at 10:00 -> +2:00).
    /// Returns the new delay. Only the delay changes; a drift correction, if any, is kept. The line is remembered as
    /// the first point for `correctDrift`.
    @discardableResult
    func align(track: Track, to cue: SubtitleItem) -> Int {
        let delay = timing.align(track, toFile: cue.startMs, atVideo: currentPositionMs())
        showDelayToast(track)
        return delay
    }

    /// Fits `track` to the line aligned before and to `cue` being the line on screen right now, which corrects a file
    /// made for another frame rate. Asked for explicitly; nothing else changes the scale. With linked tracks both
    /// get it. Without an earlier `align`, or when the lines do not give a usable fit, nothing changes.
    func correctDrift(track: Track, to cue: SubtitleItem) -> SubtitleDrift.Fit? {
        let fit = timing.correctDrift(track, toFile: cue.startMs, atVideo: currentPositionMs())
        if case .fitted? = fit { showToast(timingSummary) }
        return fit
    }

    /// Back to 1:1 with the video, keeping the line that is on screen now where it is.
    func resetDrift(track: Track) {
        timing.resetDrift(track, atVideo: currentPositionMs())
        showToast(timingSummary)
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
        if let snapshot = sessionSnapshot() { history.record(snapshot) }
        history.cancelScheduledSave()
        SubtitleTranslator.shared.cancel()
        previousSecondary = nil
        canUndoSecondary = false
        var session = restoring ?? ViewingSession(primary: primary, secondary: secondary, title: title, names: names, sourceID: sourceID)
        session.openedAt = Date()
        currentSession = nil
        if let restoring {
            ViewingDisplaySettings.restore(restoring.display, to: .standard)
            SubtitleScreenPreferences.acceptRestoredSettings()
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
        timing = DualTrackTiming(saved: saved, linked: restoring?.linked ?? timing.linked)
        timingTitle = timingKey
        currentSession = session
        restoredTiming = timing.isAdjusted
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
    var timingSummary: String { timing.summary(hasSecondary: secondary != nil) }

    /// The loaded Track 1, as the source for a translated Track 2.
    var primaryDocument: SubtitleDocument? { primary }

    /// Replaces Track 2 with `document`, which is timed within Track 1's cues (a translation of it), so it also takes
    /// Track 1's delay.
    func setSecondary(_ document: SubtitleDocument, name: String) {
        guard !trackNames.isEmpty else { return }
        previousSecondary = (secondary, trackNames.count > 1 ? trackNames[1] : nil, packageTracks?.secondaryID,
                             timing.secondarySnapshot)
        canUndoSecondary = true
        packageTracks?.secondaryID = nil
        secondary = document
        currentSession?.secondarySRT = document.srt
        trackNames = [trackNames[0], name]
        durationMs = max(durationMs, documentDurationMs)
        timing.matchSecondaryToPrimary()
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
    var translationPositionMs: Int { fileTimeMs(track: .primary) }

    func undoSecondary() {
        guard let previousSecondary else { return }
        secondary = previousSecondary.document
        currentSession?.secondarySRT = secondary?.srt
        trackNames = [trackNames[0]] + (previousSecondary.name.map { [$0] } ?? [])
        packageTracks?.secondaryID = previousSecondary.trackID
        timing.restore(previousSecondary.timing)
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
        if !hadSecondary && secondary != nil { timing.matchSecondaryToPrimary() }
        timing.clearAnchors()
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
                let (first, second) = try await ViewingHistory.documents(of: session)
                guard !Task.isCancelled, historyRestoreID == token, loadID == initialLoad else { return }
                load(primary: first, secondary: second, title: session.title, names: session.names, restoring: session)
                refreshNowPlaying()
                showControlCenterPage("nowPlaying")
            } catch {
                guard !Task.isCancelled, historyRestoreID == token else { return }
                history.fail(error)
            }
        }
    }

    func removeSession(id: String?) {
        historyRestoreTask?.cancel()
        historyRestoreID = UUID()
        if id == nil || currentSession?.id == id { currentSession = nil; timingTitle = nil }
        history.remove(id: id) { [timingStore] removed in
            for id in removed { timingStore.save(SavedTiming(), title: "session." + id) }
        }
    }

    private func sessionSnapshot() -> ViewingSession? {
        guard var session = currentSession else { return nil }
        SubtitleScreenPreferences.saveCurrentLayout()
        session.names = trackNames
        session.timing = timing.saved
        session.linked = timing.linked
        session.display = ViewingDisplaySettings.capture(.standard)
        return session
    }

    private func queueSessionSave() {
        history.scheduleSave { [weak self] in self?.sessionSnapshot() }
    }

    func flushHistory() async {
        await history.flush(pending: sessionSnapshot())
    }

    var subtitleHealthKey: String {
        SubtitleHealth.key(primary: primary, secondary: secondary, timing: timing, status: syncStatus,
                           isShowingText: !currentText.isEmpty || !secondaryText.isEmpty, positionMs: currentPositionMs())
    }

    private func recordDiagnostic(_ event: String) { diagnosticEvents.record(event) }

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
            "primaryOffsetMs": timeOffsetMs, "secondaryOffsetMs": secondaryOffsetMs, "primaryScale": timing.primaryScale,
            "secondaryScale": timing.secondaryScale, "health": subtitleHealthKey,
            "events": diagnosticEvents.entries]
        if let lastReportUptime = playback.lastReportUptime {
            snapshot["lastReportAgeSeconds"] = max(0, ProcessInfo.processInfo.systemUptime - lastReportUptime)
        }
        do { try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }

    private func saveOffsets() {
        guard let title = timingTitle else { return }
        timingStore.save(timing.saved, title: title)
        queueSessionSave()
    }


    func adjustDelay(track: Track, delta: Int) {
        setDelay(track: track, ms: delta == Int.min ? 0 : timing.offsetMs(track) + delta)
    }

    /// Sets a track's delay outright (typed value, reset, or a step) and confirms it on screen.
    func setDelay(track: Track, ms: Int) {
        timing.setDelay(track, ms: ms)
        showDelayToast(track)
    }

    private func showDelayToast(_ track: Track) {
        let key = timing.linked && secondary != nil ? "delay.toast.linked" : (track.isSecondary ? "delay.toast.secondary" : "delay.toast.primary")
        showToast(AppLocalization.format(key, String(format: "%+d ms", timing.offsetMs(track))))
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
        timing.setLinked(on)
    }

    /// For loaders that supply a file-level delay and an extra delay for Track B (B = A + extra).
    func applyDelays(primary: Int, secondaryExtra: Int) {
        timing.applyDelays(primary: primary, secondaryExtra: secondaryExtra,
                           preferredLink: UserDefaults.standard.object(forKey: "linkSecondaryDelay") as? Bool ?? true)
        // The delays given here replace any restored ones, so the "restored" notice no longer applies.
        if restoredTiming { delayToast = nil }
        restoredTiming = false
    }

}
