import Foundation

/// A player that reports Now Playing information.
nonisolated struct SyncApp: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// What is driving the subtitles right now, as shown by the status indicators.
nonisolated enum SyncStatus: Equatable, Sendable {
    /// The user chose the manual clock.
    case manual
    /// Following a player's Now Playing clock.
    case following(app: String, playing: Bool)
    /// Automatic mode, but the chosen player reports no playback; `otherApp` is a player that does.
    case waiting(otherApp: SyncApp?)
    /// Waiting for the listener's first report, including a valid no-media report.
    case connecting
    /// The system playback listener stopped and is being restarted.
    case disconnected

    var isFollowing: Bool { if case .following = self { true } else { false } }

    /// - Parameter followedApp: the player whose clock currently drives the subtitles, if any.
    static func current(manualMode: Bool, listenerAlive: Bool, followedApp: String?, playing: Bool,
                        ignoredApp: SyncApp?) -> SyncStatus {
        if manualMode { return .manual }
        if !listenerAlive { return .disconnected }
        if let followedApp { return .following(app: followedApp, playing: playing) }
        return .waiting(otherApp: ignoredApp)
    }
}

/// One Now Playing report, reduced to what subtitle sync uses.
nonisolated struct NowPlayingReport: Sendable {
    var bundleID: String?
    var appName: String?
    var isPlaying: Bool?
    var playbackRate: Double?
    var elapsedMicros: Double?
    var timestampEpochMicros: Double?
    var durationMicros: Double?

    var app: SyncApp? { bundleID.map { SyncApp(id: $0, name: appName ?? $0) } }

    /// Some players omit isPlaying or report a zero rate while playing; trust whichever signal says "playing".
    var playing: Bool { isPlaying ?? ((playbackRate ?? 0) > 0) }

    /// Elapsed playback time at `epochSeconds`. A playing report is advanced by the time since its timestamp;
    /// reports without a timestamp, or with one over an hour old, are taken as they are.
    func elapsedSeconds(atEpoch epochSeconds: Double) -> Double? {
        guard let elapsedMicros else { return nil }
        var seconds = elapsedMicros / 1_000_000
        if playing, let timestampEpochMicros {
            let age = epochSeconds - timestampEpochMicros / 1_000_000
            let rate = playbackRate ?? 0
            if age > 0 && age < 3600 { seconds += age * (rate > 0 ? rate : 1) }
        }
        return seconds
    }
}

/// Follows the chosen player's Now Playing reports with a clock that extrapolates between them.
nonisolated struct PlaybackTracker: Sendable {
    /// Follow every player.
    static let anyApp = "*"
    /// Position differences below this are report jitter rather than seeks.
    static let jitterMs = 150.0

    private(set) var clock = SubtitleClock()
    /// The player the clock belongs to, while it is valid.
    private(set) var followedApp: SyncApp?
    /// A player reporting playback that is not the one followed.
    private(set) var ignoredApp: SyncApp?
    /// Length of the followed media, when the player reports it.
    private(set) var durationMs: Int?
    /// Playback speed the player is set to, kept while paused (the clock's own rate is 0 then).
    private(set) var playbackRate = 1.0

    /// Takes a report, or nil when nothing is playing. Returns false when the report gives no usable position for
    /// `target` (a bundle identifier or `anyApp`); the caller then calls `invalidate()` once it has read the clock.
    mutating func receive(_ report: NowPlayingReport?, target: String, uptime: TimeInterval, epoch: Double) -> Bool {
        guard let report, let app = report.app else {
            ignoredApp = nil
            return false
        }
        guard target == Self.anyApp || app.id == target else {
            ignoredApp = report.playing && report.elapsedMicros != nil ? app : nil
            return false
        }
        ignoredApp = nil
        guard let elapsed = report.elapsedSeconds(atEpoch: epoch), elapsed.isFinite, elapsed >= 0, elapsed < 36_000_000 else {
            return false
        }
        let reportedRate = report.playbackRate ?? 0
        let rate = reportedRate > 0 ? reportedRate : 1
        let validRate = rate.isFinite && rate <= 16
        let newRate = report.playing && validRate ? rate : 0
        if validRate { playbackRate = rate }
        // Small differences are jitter: keep most of the extrapolated position so subtitles do not flicker.
        let expected = clock.valid ? Double(clock.position(at: uptime)) : -.infinity
        if abs(expected - elapsed * 1000) < Self.jitterMs && clock.rate == newRate {
            clock.positionMs = expected + (elapsed * 1000 - expected) * 0.5
            clock.uptime = uptime
        } else {
            clock = SubtitleClock(positionMs: elapsed * 1000, uptime: uptime, rate: newRate, valid: true)
        }
        followedApp = app
        durationMs = report.durationMicros.flatMap {
            $0.isFinite && $0 > 0 && $0 < 36_000_000_000_000 ? Int($0 / 1000) : nil
        }
        return true
    }

    mutating func invalidate() {
        clock.valid = false
        followedApp = nil
        durationMs = nil
    }

    /// Forgets the other player, for example once the user changed which player to follow.
    mutating func clearIgnoredApp() {
        ignoredApp = nil
    }

    /// Moves the valid clock, after asking the player to seek, so the new position shows before its next report.
    mutating func seek(toMs position: Int, uptime: TimeInterval) {
        clock.positionMs = Double(position)
        clock.uptime = uptime
    }
}

/// Delays of both tracks, as saved per title.
nonisolated struct SavedTiming: Codable, Equatable, Sendable {
    var primaryOffsetMs = 0
    var secondaryOffsetMs = 0

    var isDefault: Bool { self == SavedTiming() }
}

/// Saves timing per title in user defaults: delays under "offsets.<title>" as [A, B, 0] (older versions wrote
/// [A, extra] with B = A + extra). Defaults are not stored. Subtitle time maps 1:1 to video time, so the timeline speeds
/// older versions stored under "speeds.<title>" are ignored and removed on the next save.
nonisolated struct SubtitleTimingStore {
    let defaults: UserDefaults

    func load(sessionID: String, legacyTitle: String) -> SavedTiming {
        let key = "session." + sessionID
        if defaults.object(forKey: "offsets." + key) != nil { return load(title: key) }
        guard !legacyTitle.isEmpty, defaults.object(forKey: "offsets." + legacyTitle) != nil else { return SavedTiming() }
        let timing = load(title: legacyTitle)
        save(timing, title: key)
        save(SavedTiming(), title: legacyTitle)
        return timing
    }

    func load(title: String) -> SavedTiming {
        var timing = SavedTiming()
        if let offsets = defaults.array(forKey: "offsets." + title) as? [Int], let first = offsets.first {
            timing.primaryOffsetMs = first
            timing.secondaryOffsetMs = offsets.count > 2 ? offsets[1] : first + (offsets.count > 1 ? offsets[1] : 0)
        }
        return timing
    }

    func save(_ timing: SavedTiming, title: String) {
        if timing.primaryOffsetMs == 0 && timing.secondaryOffsetMs == 0 {
            defaults.removeObject(forKey: "offsets." + title)
        } else {
            defaults.set([timing.primaryOffsetMs, timing.secondaryOffsetMs, 0], forKey: "offsets." + title)
        }
        defaults.removeObject(forKey: "speeds." + title)
    }
}
