import Foundation

nonisolated struct LocalSubtitleTrack: Identifiable, Sendable {
    let id: String
    let language: String
    let name: String
    let forced: Bool
    let sdh: Bool
    let streamDirectory: URL
    let playlistURL: URL
    let segments: [LocalSubtitleSegment]
    let episodeSegment: Int

    var label: String {
        "\(name) [\(language)]"
            + (forced ? " · " + subtitleLocalizedString("track.forced") : "")
            + (sdh ? " · " + subtitleLocalizedString("track.sdhCc") : "")
    }
}

nonisolated struct LocalSubtitleSegment: Sendable {
    let file: URL
    let offset: Int
    let length: Int
    let startMs: Int
    let durationMs: Int
    let sequence: Int
}

nonisolated enum MovpkgSubtitleExtractor {
    // Match the subtitle parser's 10,000-hour bound before converting seconds to integer milliseconds.
    private static let maximumTimelineSeconds = 36_000_000.0

    static func inspect(_ packageURL: URL) throws -> [LocalSubtitleTrack] {
        let package = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard package.pathExtension.lowercased() == "movpkg",
              FileManager.default.fileExists(atPath: package.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SubtitleError.message("error.movpkg.notSelected")
        }

        guard try XMLTree.read(package.appendingPathComponent("boot.xml")).name == "HLSMoviePackage" else {
            throw SubtitleError.message("error.movpkg.invalid")
        }
        let streamDirs = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("2-") }
        var localStreams: [String: (URL, XMLTree)] = [:]
        for candidate in streamDirs {
            try Task.checkCancellation()
            guard let directory = try? containedURL(candidate.lastPathComponent, in: package),
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let infoURL = directory.appendingPathComponent("StreamInfoBoot.xml")
            guard FileManager.default.fileExists(atPath: infoURL.path) else { continue }
            guard let info = try? XMLTree.read(infoURL) else { continue }
            guard info.descendant("Complete")?.text == "YES",
                  info.descendant("Type")?.text == "Supplemental",
                  info.descendants("MediaType").contains(where: { $0.attributes["type"] == "sbtl" }),
                  let stableID = info.descendant("UniqueIdentifier")?.text,
                  let playlistPath = info.descendant("PathToLocalCopy")?.text else { continue }
            guard let playlistURL = try? containedURL(playlistPath, in: directory),
                  let playlist = try? String(contentsOf: playlistURL, encoding: .utf8) else { continue }
            guard playlist.hasPrefix("#EXTM3U"), !playlist.contains("#EXT-X-KEY:") else { continue }
            localStreams[stableID] = (directory, info)
        }

        let masterURLs = try FileManager.default.contentsOfDirectory(at: package.appendingPathComponent("Data"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-master.m3u8") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for masterURL in masterURLs {
            try Task.checkCancellation()
            guard let master = try? String(contentsOf: masterURL, encoding: .utf8) else { continue }
            let renditions = master.components(separatedBy: .newlines).filter { $0.hasPrefix("#EXT-X-MEDIA:") }
            var tracks: [LocalSubtitleTrack] = []
            for line in renditions {
                try Task.checkCancellation()
                let fields = SubtitlePlaylist.attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard fields["TYPE"] == "SUBTITLES",
                      let stableID = fields["STABLE-RENDITION-ID"],
                      let language = fields["LANGUAGE"],
                      let (directory, info) = localStreams[stableID] else { continue }
                let xmlSegments = info.descendants("SEG").sorted { (Int($0.attributes["SeqNum"] ?? "0") ?? 0) < (Int($1.attributes["SeqNum"] ?? "0") ?? 0) }
                guard !xmlSegments.isEmpty else { continue }
                let segments = try? xmlSegments.map { item -> LocalSubtitleSegment in
                    guard let path = item.attributes["PATH"], let offset = Int(item.attributes["Off"] ?? "0"),
                          let length = Int(item.attributes["Len"] ?? "0"),
                          let sequence = Int(item.attributes["SeqNum"] ?? "0"),
                          let start = Double(item.attributes["Tim"] ?? ""), let duration = Double(item.attributes["Dur"] ?? ""),
                          offset >= 0, length > 0, sequence >= 0,
                          start.isFinite, duration.isFinite, start >= 0, duration > 0,
                          start < maximumTimelineSeconds, duration < maximumTimelineSeconds,
                          start + duration < maximumTimelineSeconds else {
                        throw SubtitleError.message("error.movpkg.invalidOffset")
                    }
                    let file = try containedURL(path, in: directory)
                    let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    guard offset <= size, length <= size - offset, length <= 50_000_000 else {
                        throw SubtitleError.message("error.movpkg.invalidByteRange")
                    }
                    return LocalSubtitleSegment(file: file, offset: offset, length: length,
                                                startMs: Int((start * 1000).rounded()), durationMs: Int((duration * 1000).rounded()),
                                                sequence: sequence)
                }
                guard let segments,
                      let episodeSegment = segments.indices.max(by: { segments[$0].durationMs < segments[$1].durationMs }) else { continue }
                tracks.append(LocalSubtitleTrack(id: stableID, language: language,
                                                 name: fields["NAME"] ?? language, forced: fields["FORCED"] == "YES",
                                                 sdh: fields["CHARACTERISTICS"]?.contains("public.accessibility") == true,
                                                 streamDirectory: directory, playlistURL: masterURL, segments: segments,
                                                 episodeSegment: episodeSegment))
            }
            if !tracks.isEmpty {
                return tracks.sorted {
                    if $0.forced != $1.forced { return !$0.forced }
                    if $0.language != $1.language { return $0.language < $1.language }
                    if $0.sdh != $1.sdh { return !$0.sdh }
                    return $0.name < $1.name
                }
            }
        }
        throw SubtitleError.message("error.movpkg.noTracks")
    }

    static func document(for track: LocalSubtitleTrack, packageTimeline: Bool) throws -> SubtitleDocument {
        var items: [SubtitleItem] = []
        let selected = packageTimeline ? Array(track.segments.indices) : [track.episodeSegment]
        for index in selected {
            try Task.checkCancellation()
            let segment = track.segments[index]
            let data = try Data(contentsOf: segment.file, options: .mappedIfSafe)
            let range = segment.offset..<(segment.offset + segment.length)
            guard range.upperBound <= data.count,
                  let text = String(data: data.subdata(in: range), encoding: .utf8), text.hasPrefix("WEBVTT") else {
                throw SubtitleError.message("error.movpkg.invalidSegment")
            }
            let parsed = try SubtitleDocument.parse(text, allowEmpty: true)
            guard let map = parsed.map, map.localMs == 0, abs(map.mpegMs - 10_000) < 1 else {
                throw SubtitleError.message("error.movpkg.timeMapMismatch")
            }
            for item in parsed.document.items {
                guard item.endMs <= segment.durationMs + 2 else {
                    throw SubtitleError.message("error.movpkg.cueOutOfRange")
                }
                let start = packageTimeline ? segment.startMs + item.startMs : item.startMs
                let end = packageTimeline ? segment.startMs + item.endMs : item.endMs
                items.append(SubtitleItem(startMs: start, endMs: end, text: item.text))
            }
        }
        return try SubtitleDocument(items: items)
    }

    private static func containedURL(_ relativePath: String, in root: URL) throws -> URL {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let url = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(rootPath + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw SubtitleError.message("error.movpkg.missingFile")
        }
        return url
    }
}

private nonisolated final class XMLTree: NSObject, XMLParserDelegate, @unchecked Sendable {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLTree] = []
    private var stack: [XMLTree] = []

    private init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    static func read(_ url: URL) throws -> XMLTree {
        guard let parser = XMLParser(contentsOf: url) else {
            throw SubtitleError.message("error.movpkg.metadataUnreadable")
        }
        let tree = XMLTree(name: "root")
        parser.delegate = tree
        guard parser.parse(), let result = tree.children.first else {
            throw SubtitleError.message("error.movpkg.metadataInvalid")
        }
        return result
    }

    func descendants(_ element: String) -> [XMLTree] {
        children.flatMap { ($0.name == element ? [$0] : []) + $0.descendants(element) }
    }

    func descendant(_ element: String) -> XMLTree? {
        descendants(element).first
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLTree(name: elementName, attributes: attributeDict)
        (stack.last ?? self).children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}
