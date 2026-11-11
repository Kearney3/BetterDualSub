import Foundation

/// The two subtitle tracks shown together.
nonisolated enum Track: String, CaseIterable, Hashable, Sendable {
    case primary, secondary

    init(secondary: Bool) { self = secondary ? .secondary : .primary }

    var isSecondary: Bool { self == .secondary }
    var other: Track { isSecondary ? .primary : .secondary }
}

/// How each track is placed on the video's timeline: a delay and a drift correction per track, whether Track 2
/// follows Track 1, and the line last aligned on each track (the first point of a drift correction). Delays move a
/// track; only `correctDrift` and `resetDrift` change a track's scale (`SubtitleDrift`). Everything here is plain
/// arithmetic, so the playback code and the tests use the same rules.
nonisolated struct DualTrackTiming: Equatable, Sendable {
    static let delayLimitMs = 86_400_000

    private(set) var primaryOffsetMs = 0
    private(set) var secondaryOffsetMs = 0
    private(set) var primaryScale = 1.0
    private(set) var secondaryScale = 1.0
    /// While on, Track 2 always has Track 1's delay and drift correction.
    private(set) var linked: Bool
    private var anchors: [Track: SubtitleDrift.Point] = [:]

    init(linked: Bool = true) { self.linked = linked }

    /// Saved timing restored on load. Linked tracks take Track 1's values, as they were saved from it.
    init(saved: SavedTiming, linked: Bool) {
        self.linked = linked
        primaryOffsetMs = Self.bounded(saved.primaryOffsetMs)
        primaryScale = saved.primaryScale
        secondaryOffsetMs = linked ? primaryOffsetMs : Self.bounded(saved.secondaryOffsetMs)
        secondaryScale = linked ? primaryScale : saved.secondaryScale
    }

    var saved: SavedTiming {
        SavedTiming(primaryOffsetMs: primaryOffsetMs, secondaryOffsetMs: secondaryOffsetMs,
                    primaryScale: primaryScale, secondaryScale: secondaryScale)
    }

    /// Any delay or drift correction is in effect.
    var isAdjusted: Bool { !saved.isDefault }

    func offsetMs(_ track: Track) -> Int { track.isSecondary ? secondaryOffsetMs : primaryOffsetMs }
    func scale(_ track: Track) -> Double { track.isSecondary ? secondaryScale : primaryScale }
    func anchor(_ track: Track) -> SubtitleDrift.Point? { anchors[track] }

    static func bounded(_ ms: Int) -> Int { max(-delayLimitMs, min(delayLimitMs, ms)) }

    // MARK: Mapping

    /// Where `videoMs` falls in a track's own file: the video time less the delay, over the drift correction.
    func fileTimeMs(_ track: Track, atVideo videoMs: Int) -> Int {
        SubtitleDrift.fileTime(atVideo: videoMs, offsetMs: offsetMs(track), scale: scale(track))
    }

    func videoTimeMs(_ track: Track, ofFile fileMs: Int) -> Int {
        SubtitleDrift.videoTime(ofFile: fileMs, offsetMs: offsetMs(track), scale: scale(track))
    }

    /// How far Track 2's lines sit from Track 1's in Track 1's file time, for snapping them together. Tracks with
    /// different drift corrections are not a constant shift apart, so there is none.
    var snapShiftMs: Int? {
        primaryScale == secondaryScale ? Int((Double(primaryOffsetMs - secondaryOffsetMs) / primaryScale).rounded()) : nil
    }

    // MARK: Delays

    /// Sets a track's delay (limited to a day either way). With linked tracks both get it.
    mutating func setDelay(_ track: Track, ms: Int) {
        let value = Self.bounded(ms)
        if track.isSecondary { secondaryOffsetMs = value } else { primaryOffsetMs = value }
        if linked { if track.isSecondary { primaryOffsetMs = value } else { secondaryOffsetMs = value } }
    }

    /// Turning the link on gives Track 2 Track 1's delay and drift correction.
    mutating func setLinked(_ on: Bool) {
        linked = on
        guard on else { return }
        secondaryScale = primaryScale
        secondaryOffsetMs = primaryOffsetMs
    }

    /// For loaders that supply a file-level delay and an extra delay for Track 2 (Track 2 = Track 1 + extra); any extra
    /// unlinks the tracks. Drift corrections and anchors are kept.
    mutating func applyDelays(primary: Int, secondaryExtra: Int, preferredLink: Bool) {
        linked = secondaryExtra == 0 ? preferredLink : false
        primaryOffsetMs = Self.bounded(primary)
        secondaryOffsetMs = linked ? primaryOffsetMs : Self.bounded(primary + secondaryExtra)
        if linked { secondaryScale = primaryScale }
    }

    /// A newly shown Track 2 (a translation of Track 1) starts where Track 1 is.
    mutating func matchSecondaryToPrimary() {
        secondaryScale = primaryScale
        secondaryOffsetMs = primaryOffsetMs
        anchors[.secondary] = nil
    }

    /// What `restore` needs to put Track 2 back as it was, for undoing a replaced Track 2.
    struct SecondarySnapshot: Equatable, Sendable {
        let offsetMs: Int
        let scale: Double
        let linked: Bool
    }

    var secondarySnapshot: SecondarySnapshot { SecondarySnapshot(offsetMs: secondaryOffsetMs, scale: secondaryScale, linked: linked) }

    mutating func restore(_ snapshot: SecondarySnapshot) {
        linked = snapshot.linked
        secondaryScale = snapshot.scale
        anchors[.secondary] = nil
        setDelay(.secondary, ms: snapshot.offsetMs)
    }

    mutating func clearAnchors() { anchors = [:] }

    // MARK: Alignment and drift

    /// Makes the file line at `fileMs` the one on screen at `videoMs`, keeping the track's drift correction, and
    /// remembers it as the first point for `correctDrift`. Returns the new delay.
    @discardableResult
    mutating func align(_ track: Track, toFile fileMs: Int, atVideo videoMs: Int) -> Int {
        let point = SubtitleDrift.Point(fileMs: fileMs, videoMs: videoMs)
        setDelay(track, ms: SubtitleDrift.offset(for: point, scale: scale(track)))
        anchors[track] = point
        return offsetMs(track)
    }

    /// Fits the track to the line aligned before and to the file line at `fileMs` being on screen at `videoMs`. nil
    /// without an earlier `align`. Only a usable fit changes anything; with linked tracks both get it.
    mutating func correctDrift(_ track: Track, toFile fileMs: Int, atVideo videoMs: Int) -> SubtitleDrift.Fit? {
        guard let anchor = anchors[track] else { return nil }
        let fit = SubtitleDrift.fit(anchor, SubtitleDrift.Point(fileMs: fileMs, videoMs: videoMs))
        guard case .fitted(let scale, let offsetMs) = fit else { return fit }
        setScale(track, scale)
        setDelay(track, ms: offsetMs)
        return fit
    }

    /// Back to 1:1 with the video, keeping the line that is on screen at `videoMs` where it is.
    mutating func resetDrift(_ track: Track, atVideo videoMs: Int) {
        let fileMs = fileTimeMs(track, atVideo: videoMs)
        setScale(track, 1)
        anchors[track] = nil
        setDelay(track, ms: videoMs - fileMs)
    }

    private mutating func setScale(_ track: Track, _ scale: Double) {
        if track.isSecondary || linked { secondaryScale = scale }
        if !track.isSecondary || linked { primaryScale = scale }
    }

    // MARK: Display

    /// A drift correction as shown to the user, such as "×1.0427".
    static func scaleLabel(_ scale: Double) -> String { String(format: "×%.4f", scale) }

    /// Delay (and drift correction) of each track, such as "+1200 ms ×1.0427", or both joined by " / " when they differ.
    func summary(hasSecondary: Bool) -> String {
        func describe(_ track: Track) -> String {
            String(format: "%+d ms", offsetMs(track)) + (scale(track) == 1 ? "" : " " + Self.scaleLabel(scale(track)))
        }
        guard hasSecondary, secondaryOffsetMs != primaryOffsetMs || secondaryScale != primaryScale else { return describe(.primary) }
        return describe(.primary) + " / " + describe(.secondary)
    }
}
