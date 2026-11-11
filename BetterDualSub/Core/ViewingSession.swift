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

/// Recent sessions kept in a folder: `index.json` lists the session ids, newest first, and each session is its own
/// `<id>.json`. Recording one session writes that file (when it changed) and the small index, not the whole history.
/// Writes are serial and atomic; a damaged or newer history is reported instead of silently overwritten, and only
/// clearing everything removes it.
actor ViewingSessionStore {
    /// The folder holding the index and the session files.
    let url: URL
    static let limit = 10
    static let formatVersion = 2
    private let maximumBytes: Int
    private var cached: [ViewingSession]?
    private var cachedSignature: [FileSignature?]?

    private struct FileSignature: Equatable {
        let modified: Date?
        let size: Int?
        let inode: UInt64?
    }

    private struct Index: Codable {
        var version = ViewingSessionStore.formatVersion
        var order: [String]
    }

    /// `maximumBytes` bounds the session files together, and each one on its own.
    init(url: URL, maximumBytes: Int = 100 * 1024 * 1024) {
        self.url = url
        self.maximumBytes = maximumBytes
    }

    private var indexURL: URL { url.appendingPathComponent("index.json") }
    private func fileURL(_ id: String) -> URL { url.appendingPathComponent(id + ".json") }

    private func signature(of file: URL) throws -> FileSignature? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return FileSignature(modified: attributes[.modificationDate] as? Date,
                             size: attributes[.size] as? Int, inode: attributes[.systemFileNumber] as? UInt64)
    }

    private func signatures(ids: [String]) throws -> [FileSignature?] {
        try [signature(of: indexURL)] + ids.map { try signature(of: fileURL($0)) }
    }

    func load() throws -> [ViewingSession] {
        if let cached, let cachedSignature, try signatures(ids: cached.map(\.id)) == cachedSignature { return cached }
        guard let indexSignature = try signature(of: indexURL) else {
            cached = []
            cachedSignature = try signatures(ids: [])
            return []
        }
        guard (indexSignature.size ?? 0) <= 1_000_000 else { throw SubtitleError.message("error.history.invalid") }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        guard index.version == Self.formatVersion else { throw SubtitleError.message("error.history.unsupportedVersion") }
        let decoder = JSONDecoder()
        var sessions: [ViewingSession] = []
        for id in index.order.prefix(Self.limit) {
            // The id names a file, so it must be what a session's id is: a hash in hexadecimal.
            guard !id.isEmpty, id.allSatisfy(\.isHexDigit), let file = try signature(of: fileURL(id)) else {
                throw SubtitleError.message("error.history.invalid")
            }
            guard (file.size ?? 0) <= maximumBytes else { throw SubtitleError.message("error.history.tooLarge") }
            let session = try decoder.decode(ViewingSession.self, from: Data(contentsOf: fileURL(id)))
            guard session.id == id else { throw SubtitleError.message("error.history.invalid") }
            sessions.append(session)
        }
        cached = sessions
        cachedSignature = try signatures(ids: sessions.map(\.id))
        return sessions
    }

    func record(_ session: ViewingSession) throws -> [ViewingSession] {
        let current = try load()
        if current.first == session { return current }
        var sessions = current.filter { $0.id != session.id }
        sessions.insert(session, at: 0)
        return try write(sessions, changed: session)
    }

    /// Removes one session, or all of them (also when the history is damaged) for a nil `id`.
    func remove(id: String?) throws -> [ViewingSession] {
        guard let id else {
            try? FileManager.default.removeItem(at: url)
            cached = []
            cachedSignature = try signatures(ids: [])
            return []
        }
        return try write(load().filter { $0.id != id }, changed: nil)
    }

    private func write(_ sessions: [ViewingSession], changed: ViewingSession?) throws -> [ViewingSession] {
        let previous = cached ?? []
        let data = try changed.map { try JSONEncoder().encode($0) }
        if let data, data.count > maximumBytes { throw SubtitleError.message("error.history.tooLarge") }
        func size(of id: String) throws -> Int {
            if id == changed?.id, let data { return data.count }
            return try signature(of: fileURL(id))?.size ?? 0
        }
        var retained = Array(sessions.prefix(Self.limit))
        var total = try retained.reduce(0) { try $0 + size(of: $1.id) }
        while total > maximumBytes, retained.count > 1, let oldest = retained.popLast() { total -= try size(of: oldest.id) }

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let changed, let data, previous.first(where: { $0.id == changed.id }) != changed || !FileManager.default.fileExists(atPath: fileURL(changed.id).path) {
            try data.write(to: fileURL(changed.id), options: .atomic)
        }
        if retained.map(\.id) != previous.map(\.id) || !FileManager.default.fileExists(atPath: indexURL.path) {
            try JSONEncoder().encode(Index(order: retained.map(\.id))).write(to: indexURL, options: .atomic)
        }
        // Files of sessions that left the history go last, so a failure above never loses a listed session.
        let kept = Set(retained.map(\.id))
        for old in previous where !kept.contains(old.id) { try? FileManager.default.removeItem(at: fileURL(old.id)) }
        cached = retained
        cachedSignature = try signatures(ids: retained.map(\.id))
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
    /// `package` is an Apple TV .movpkg or a video file with embedded subtitle tracks.
    case movie(URL), package(URL), files([URL]), unsupported

    init(urls: [URL]) {
        if urls.count == 1, let url = urls.first, url.isFileURL,
           (["movpkg"] + VideoSubtitleExtractor.fileExtensions).contains(url.pathExtension.lowercased()) {
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
