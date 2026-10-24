import Foundation
import CryptoKit

/// Self-contained subtitles: reopening a session never needs the original file, network, or a video seek.
nonisolated struct ViewingSession: Codable, Equatable, Identifiable, Sendable {
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
        let primarySRT = primary.srt, secondarySRT = secondary?.srt
        let identity = [sourceID, primarySRT, secondarySRT ?? ""].joined(separator: "\u{0}")
        id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        self.title = title
        self.names = names
        self.primarySRT = primarySRT
        self.secondarySRT = secondarySRT
        timing = SavedTiming()
        linked = true
        openedAt = Date()
    }
}

/// Serial, atomic writes; a damaged history is reported instead of silently overwritten.
actor ViewingSessionStore {
    let url: URL
    static let limit = 10
    private let maximumBytes: Int
    private var cached: [ViewingSession]?
    private var cachedSignature: FileSignature?

    private struct FileSignature: Equatable {
        let modified: Date?
        let size: Int?
        let inode: UInt64?
    }

    private struct Archive: Codable {
        var version = 1
        let sessions: [ViewingSession]
    }

    init(url: URL, maximumBytes: Int = 100 * 1024 * 1024) {
        self.url = url
        self.maximumBytes = maximumBytes
    }

    private func signature() throws -> FileSignature? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileSignature(modified: attributes[.modificationDate] as? Date,
                             size: attributes[.size] as? Int, inode: attributes[.systemFileNumber] as? UInt64)
    }

    func load() throws -> [ViewingSession] {
        let current = try signature()
        if let cached, current == cachedSignature { return cached }
        guard let current else { cached = []; cachedSignature = nil; return [] }
        guard (current.size ?? 0) <= maximumBytes else { throw SubtitleError.message("error.history.tooLarge") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw SubtitleError.message("error.history.tooLarge") }
        let decoder = JSONDecoder()
        let sessions: [ViewingSession]
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
            sessions = try decoder.decode([ViewingSession].self, from: data)
        } else {
            let archive = try decoder.decode(Archive.self, from: data)
            guard archive.version == 1 else { throw SubtitleError.message("error.history.unsupportedVersion") }
            sessions = archive.sessions
        }
        cached = Array(sessions.prefix(Self.limit))
        cachedSignature = current
        return cached ?? []
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
        if sessions == cached, try signature() == cachedSignature { return sessions }
        var retained = sessions
        var data = try JSONEncoder().encode(Archive(sessions: retained))
        while data.count > maximumBytes, retained.count > 1 {
            retained.removeLast()
            data = try JSONEncoder().encode(Archive(sessions: retained))
        }
        guard data.count <= maximumBytes else { throw SubtitleError.message("error.history.tooLarge") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        cached = retained
        cachedSignature = try signature()
        return retained
    }
}

/// Only appearance preferences are saved; no account identifiers, shortcuts or update/privacy settings.
nonisolated enum ViewingDisplaySettings {
    static let keys = ["primaryFontFamily", "secondaryFontFamily", "primaryFontSize", "secondaryFontSize",
                       "primaryFontWeight", "secondaryFontWeight", "primaryTextColor", "secondaryTextColor",
                       "primaryOutlineColor", "secondaryOutlineColor", "primaryOutlinePixels", "secondaryOutlinePixels",
                       "primaryLineMode", "secondaryLineMode", "primaryShadow", "secondaryShadow", "backgroundStyle", "customBackgroundColor",
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
