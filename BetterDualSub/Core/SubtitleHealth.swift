import Foundation

/// Why subtitles may not be showing, as the localization key of the explanation. Only the state of the loaded tracks
/// and the clock is looked at, never the text.
nonisolated enum SubtitleHealth {
    static func key(primary: SubtitleDocument?, secondary: SubtitleDocument?, timing: DualTrackTiming,
                    status: SyncStatus, isShowingText: Bool, positionMs: Int) -> String {
        guard let primary else { return "health.noSubtitles" }
        if status == .manual { return "health.manual" }
        if !status.isFollowing { return "health.noClock" }
        if isShowingText { return "health.cue" }
        // The span of the video the subtitles cover, with both tracks placed by their delays and drift corrections.
        let start = min(timing.videoTimeMs(.primary, ofFile: primary.items.first?.startMs ?? 0),
                        secondary.map { timing.videoTimeMs(.secondary, ofFile: $0.items.first?.startMs ?? 0) } ?? Int.max)
        let end = max(timing.videoTimeMs(.primary, ofFile: primary.duration),
                      secondary.map { timing.videoTimeMs(.secondary, ofFile: $0.duration) } ?? Int.min)
        return positionMs < start || positionMs >= end ? "health.outside" : "health.gap"
    }
}

/// The last few events of the playback listener, for the exported diagnostics. Repeats of the latest event are dropped.
nonisolated struct DiagnosticEvents: Equatable, Sendable {
    static let limit = 30
    private(set) var entries: [[String: String]] = []

    mutating func record(_ event: String, at date: Date = Date()) {
        guard entries.last?["event"] != event else { return }
        entries.append(["event": event, "time": date.formatted(.iso8601)])
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}
