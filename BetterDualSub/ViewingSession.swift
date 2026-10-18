import Foundation
import CryptoKit

/// Self-contained subtitles: reopening a session never needs the original file, network, or a video seek.
nonisolated struct ViewingSession: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var names: [String]
    var primarySRT: String
    var secondarySRT: String?
    var timing: SavedTiming
    var linked: Bool
    var display: Data?
    var openedAt: Date

    init(primary: SubtitleDocument, secondary: SubtitleDocument?, title: String, names: [String], sourceID: String) {
        // Include the source edition/timeline and both original files; translations keep this original identity.
        let identity = [sourceID, primary.srt, secondary?.srt ?? ""].joined(separator: "\u{0}")
        id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        self.title = title
        self.names = names
        primarySRT = primary.srt
        secondarySRT = secondary?.srt
        timing = SavedTiming()
        linked = true
        openedAt = Date()
    }
}

/// Serial, atomic writes; a damaged history is reported instead of silently overwritten.
actor ViewingSessionStore {
    let url: URL
    static let limit = 10

    init(url: URL) { self.url = url }

    func load() throws -> [ViewingSession] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ViewingSession].self, from: Data(contentsOf: url))
    }

    func record(_ session: ViewingSession) throws -> [ViewingSession] {
        var sessions = try load().filter { $0.id != session.id }
        sessions.insert(session, at: 0)
        return try write(Array(sessions.prefix(Self.limit)))
    }

    func remove(id: String?) throws -> [ViewingSession] {
        guard let id else { return try write([]) }
        return try write(load().filter { $0.id != id })
    }

    private func write(_ sessions: [ViewingSession]) throws -> [ViewingSession] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(sessions).write(to: url, options: .atomic)
        return sessions
    }
}

/// Only appearance preferences are saved; no account identifiers, shortcuts or update/privacy settings.
nonisolated enum ViewingDisplaySettings {
    static let keys = ["primaryFontFamily", "secondaryFontFamily", "primaryFontSize", "secondaryFontSize",
                       "primaryFontWeight", "secondaryFontWeight", "primaryTextColor", "secondaryTextColor",
                       "primaryOutlineColor", "secondaryOutlineColor", "primaryOutlinePixels", "secondaryOutlinePixels",
                       "primaryLineMode", "secondaryLineMode", "backgroundStyle", "customBackgroundColor",
                       "customBackgroundOpacity", "customBackgroundRadius", "subtitleDisplayID", "subtitleScreenLayouts",
                       "subtitleOffsetX", "subtitleOffsetY"]

    static func capture(_ defaults: UserDefaults) -> Data? {
        let values = defaults.dictionaryRepresentation().filter { keys.contains($0.key) }
        return try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    static func restore(_ data: Data?, to defaults: UserDefaults) {
        guard let data, let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for key in keys {
            if let value = values[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}

nonisolated enum SubtitleInput: Equatable {
    case movie(URL), package(URL), files([URL]), unsupported

    init(urls: [URL]) {
        if urls.count == 1, let url = urls.first, url.isFileURL, url.pathExtension.lowercased() == "movpkg" {
            self = .package(url)
        } else if (1...2).contains(urls.count), urls.allSatisfy({ $0.isFileURL && (SubtitleFileReader.fileExtensions + ["txt"]).contains($0.pathExtension.lowercased()) }) {
            self = .files(Array(urls.prefix(2)))
        } else if urls.count == 1, let url = urls.first, !url.isFileURL, (try? MoviePage(url.absoluteString)) != nil {
            self = .movie(url)
        } else { self = .unsupported }
    }
}

/// Language choices shared by download and local extraction. Forced/SDH tracks rank after full dialogue.
nonisolated enum SubtitleLanguagePreference {
    static func matches(_ language: String, _ preference: String) -> Bool {
        func normalized(_ value: String) -> String {
            var parts = value.lowercased().replacingOccurrences(of: "_", with: "-").components(separatedBy: "-")
            if parts.first == "cmn" { parts[0] = "zh" }
            return parts.joined(separator: "-")
        }
        let language = normalized(language), preference = normalized(preference)
        guard !preference.isEmpty else { return false }
        return language == preference || language.hasPrefix(preference + "-") || preference.hasPrefix(language + "-")
    }
}
