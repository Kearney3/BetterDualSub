import OSLog

/// Unified logging, read with Console or `script/build_and_run.sh --telemetry`. Like the exported diagnostics, messages
/// carry states, counts and status codes only: never subtitle text, titles, file paths, URLs or account identifiers.
nonisolated enum AppLog {
    static let subsystem = "studio.bbit.betterdualsub"
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let translation = Logger(subsystem: subsystem, category: "translation")
    static let download = Logger(subsystem: subsystem, category: "download")
}
