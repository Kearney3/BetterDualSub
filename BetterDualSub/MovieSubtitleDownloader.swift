import Foundation

// Apple TV endpoint discovery follows iSubRip (Michael Yochpaz, MIT).
// See ThirdPartyNotices.txt for the upstream license and pinned source reference.
nonisolated struct MoviePage: Sendable {
    let id: String
    let country: String

    init(_ input: String) throws {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "tv.apple.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw SubtitleError.message("error.download.invalidURL")
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let movie = parts.firstIndex(of: "movie"), movie <= 1,
              let id = parts.last, id.range(of: "^umc\\.cmc\\.[a-z0-9]{23,25}$", options: .regularExpression) != nil else {
            throw SubtitleError.message("error.download.unsupportedPage")
        }
        let country = movie == 1 ? parts[0].uppercased() : "US"
        guard country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw SubtitleError.message("error.download.invalidRegion")
        }
        self.id = id
        self.country = country
    }
}

nonisolated struct MovieVersion: Identifiable, Sendable {
    let id: String
    let title: String
    let durationMs: Int?
    let manifests: [URL]
    var label: String {
        title + (durationMs.map { " · " + subtitleLocalizedFormat("download.runtime.minutes", $0 / 60_000) } ?? "") + " · \(id)"
    }
}

nonisolated struct MovieSubtitleTrack: Identifiable, Sendable {
    let id: String
    let language: String
    let name: String
    let forced: Bool
    let accessibility: Bool
    var mirrors: [URL]
    var label: String {
        "\(name) [\(language)]"
            + (forced ? " · " + subtitleLocalizedString("track.forcedPartial") : "")
            + (accessibility ? " · " + subtitleLocalizedString("track.ccSdh") : "")
    }
}

nonisolated struct SubtitleSegment: Sendable {
    let url: URL
    let startMs: Int
}

nonisolated enum SubtitlePlaylist {
    static func attributes(_ value: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: "([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)")
        var result: [String: String] = [:]
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let key = Range(match.range(at: 1), in: value), let raw = Range(match.range(at: 2), in: value) else { continue }
            result[String(value[key])] = String(value[raw]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return result
    }

    static func tracks(_ content: String, baseURL: URL) throws -> [MovieSubtitleTrack] {
        guard content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw SubtitleError.message("error.download.invalidPlaylist")
        }
        var result: [MovieSubtitleTrack] = []
        for line in content.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-MEDIA:") {
            let fields = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard fields["TYPE"] == "SUBTITLES", let uri = fields["URI"], let language = fields["LANGUAGE"],
                  let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
            try MovieSubtitleDownloader.validateResource(url)
            let name = fields["NAME"] ?? language
            let forced = fields["FORCED"] == "YES"
            let cc = fields["CHARACTERISTICS"]?.contains("public.accessibility") == true
            // Apple mirrors use different GROUP-ID values for the same subtitle rendition.
            let id = [language, name, String(forced), fields["CHARACTERISTICS"] ?? "", fields["ASSOC-LANGUAGE"] ?? "",
                      fields["STABLE-RENDITION-ID"] ?? ""].joined(separator: "|")
            if let index = result.firstIndex(where: { $0.id == id }) {
                if !result[index].mirrors.contains(url) { result[index].mirrors.append(url) }
            } else {
                result.append(MovieSubtitleTrack(id: id, language: language, name: name, forced: forced, accessibility: cc, mirrors: [url]))
            }
        }
        guard !result.isEmpty else { throw SubtitleError.message("error.download.noTextTracks") }
        return result.sorted {
            if $0.forced != $1.forced { return !$0.forced }
            if $0.language != $1.language { return $0.language < $1.language }
            return $0.label < $1.label
        }
    }

    static func segments(_ content: String, baseURL: URL) throws -> [SubtitleSegment] {
        guard content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U"), content.contains("#EXT-X-ENDLIST") else {
            throw SubtitleError.message("error.download.incompletePlaylist")
        }
        var result: [SubtitleSegment] = []
        var position = 0.0
        var duration: Double?
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-KEY:"), attributes(String(line.dropFirst(11)))["METHOD"] != "NONE" {
                throw SubtitleError.message("error.download.encrypted")
            }
            if line.hasPrefix("#EXT-X-BYTERANGE") || line.hasPrefix("#EXT-X-MAP:") || line == "#EXT-X-DISCONTINUITY" {
                throw SubtitleError.message("error.download.unsupportedSegmentFormat")
            }
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",").first ?? "")
                guard let duration, duration.isFinite, duration >= 0, duration <= 86400 else {
                    throw SubtitleError.message("error.download.invalidSegmentDuration")
                }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard let segmentDuration = duration, let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                    throw SubtitleError.message("error.download.invalidSegmentURL")
                }
                try MovieSubtitleDownloader.validateResource(url)
                result.append(SubtitleSegment(url: url, startMs: Int((position * 1000).rounded())))
                position += segmentDuration
                // Consume the EXTINF so malformed playlists cannot reuse the previous duration.
                duration = nil
            }
        }
        guard !result.isEmpty, result.count <= 5000 else { throw SubtitleError.message("error.download.invalidSegmentCount") }
        return result
    }

    static func merge(_ texts: [String], segments: [SubtitleSegment]) throws -> SubtitleDocument {
        guard texts.count == segments.count else { throw SubtitleError.message("error.download.incompleteSegments") }
        var originMs: Double?
        var items: [SubtitleItem] = []
        let wrapMs = 8_589_934_592.0 / 90
        for (text, segment) in zip(texts, segments) {
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") else {
                throw SubtitleError.message("error.download.notWebVTT")
            }
            let parsed = try SubtitleDocument.parse(text, allowEmpty: true)
            var offset = 0.0
            if let map = parsed.map {
                let raw = map.mpegMs - Double(map.localMs)
                if originMs == nil { originMs = raw - Double(segment.startMs) }
                let expected = originMs! + Double(segment.startMs)
                let unwrapped = raw + ((expected - raw) / wrapMs).rounded() * wrapMs
                offset = unwrapped - originMs!
            }
            for item in parsed.document.items {
                let start = Int((Double(item.startMs) + offset).rounded())
                let end = Int((Double(item.endMs) + offset).rounded())
                if end > 0 { items.append(SubtitleItem(startMs: max(0, start), endMs: end, text: item.text)) }
            }
        }
        return try SubtitleDocument(items: items)
    }
}

private nonisolated final class AppleSubtitleRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? MovieSubtitleDownloader.validateResource(url)) != nil else {
            completionHandler(nil)
            return
        }
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name.lowercased() == "dsid" }) == true,
           !MovieSubtitleDownloader.isAccountManifest(url) {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor MovieSubtitleDownloader {
    private let session: URLSession
    private static let api = "https://tv.apple.com/api/uts/v3"
    private static let baseParams = ["utscf": "OjAAAAAAAAA~", "caller": "web", "v": "96", "pfm": "web"]

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0", "Referer": "https://tv.apple.com/"]
        self.session = session ?? URLSession(configuration: configuration, delegate: AppleSubtitleRedirectDelegate(), delegateQueue: nil)
    }

    nonisolated static func validateResource(_ url: URL) throws {
        let host = url.host?.lowercased() ?? ""
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".mzstatic.com") else {
            throw SubtitleError.message("error.download.unsupportedResourceURL")
        }
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name.lowercased() == "dsid" }) == true,
           !isAccountManifest(url) {
            throw SubtitleError.message("error.download.accountIDBlocked")
        }
    }

    nonisolated static func isAccountManifest(_ url: URL) -> Bool {
        (url.host == "play.itunes.apple.com" && url.path == "/WebObjects/MZPlay.woa/hls/playlist.m3u8") ||
        (url.host == "play-edge.itunes.apple.com" && url.path == "/WebObjects/MZPlayLocal.woa/hls/playlist.m3u8")
    }

    private func get(_ url: URL) async throws -> (String, URL) {
        try Task.checkCancellation()
        try Self.validateResource(url)
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, let finalURL = response.url else {
            throw SubtitleError.message("error.download.invalidResponse")
        }
        try Self.validateResource(finalURL)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPFailure(status: response.statusCode)
        }
        guard data.count <= 5_000_000, let content = String(data: data, encoding: .utf8) else {
            throw SubtitleError.message("error.download.invalidText")
        }
        return (content, finalURL)
    }

    private struct HTTPFailure: LocalizedError {
        let status: Int
        var errorDescription: String? {
            subtitleLocalizedFormat("error.download.httpFailure", status)
        }
    }

    private func json(_ endpoint: String, params: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: Self.api + endpoint)!
        components.queryItems = params.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        let (text, _) = try await get(components.url!)
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let data = root["data"] as? [String: Any] else { throw SubtitleError.message("error.download.apiChanged") }
        return data
    }

    func versions(for page: MoviePage) async throws -> [MovieVersion] {
        let storefronts = try await json("/storefronts", params: Self.baseParams.merging(["sf": "143441"], uniquingKeysWith: { _, new in new }))
        guard let store = storefronts[page.country] as? [String: Any], let sf = store["storefrontId"] as? NSNumber else {
            throw SubtitleError.message("error.download.unsupportedRegion")
        }
        let configuration = try await json("/configurations", params: Self.baseParams.merging(["sf": sf.stringValue], uniquingKeysWith: { _, new in new }))
        guard let props = configuration["applicationProps"] as? [String: Any], let classes = props["requiredParamsMap"] as? [String: [String: Any]],
              let storefront = props["storefront"] as? [String: Any] else { throw SubtitleError.message("error.download.apiInvalidConfig") }
        let routes = props["routes"] as? [String: [String: Any]] ?? [:]
        let route = routes.values.first(where: { $0["path"] as? String == "/uts/v3/movies/{movieId}" })
        let requiredClass = route?["requiredParamsType"] as? String ?? "Default"
        guard let required = classes[requiredClass] else { throw SubtitleError.message("error.download.apiMissingParameter") }
        var params: [String: String] = [:]
        for (key, value) in required {
            if let value = value as? String { params[key] = value }
            else if let value = value as? NSNumber { params[key] = value.stringValue }
        }
        let locales = storefront["localesSupported"] as? [String] ?? []
        let locale = locales.first(where: { $0 == "en_US" || $0 == "en_GB" }) ?? (storefront["defaultLocale"] as? String ?? "en_US")
        params["locale"] = locale.replacingOccurrences(of: "_", with: "-")
        params["sf"] = sf.stringValue
        let movie = try await json("/movies/\(page.id)", params: params)
        guard let playables = movie["playables"] as? [String: [String: Any]] else { throw SubtitleError.message("error.download.noMovieResources") }
        var result: [MovieVersion] = []
        for playable in playables.values where playable["channelId"] as? String == "tvs.sbd.9001" {
            guard let media = playable["itunesMediaApiData"] as? [String: Any], let id = media["id"] as? String,
                  let offers = media["offers"] as? [[String: Any]] else { continue }
            let metadata = playable["canonicalMetadata"] as? [String: Any] ?? [:]
            var urls: [URL] = []
            for offer in offers {
                guard let value = offer["hlsUrl"] as? String, var parts = URLComponents(string: value) else { continue }
                parts.queryItems = parts.queryItems?.filter { $0.name.lowercased() != "dsid" }
                if let url = parts.url, !urls.contains(url) { try Self.validateResource(url); urls.append(url) }
            }
            if !urls.isEmpty {
                result.append(MovieVersion(id: id, title: metadata["movieTitle"] as? String ?? subtitleLocalizedString("common.movie"),
                                           durationMs: offers.first?["durationInMilliseconds"] as? Int, manifests: urls))
            }
        }
        guard !result.isEmpty else {
            if playables.values.contains(where: { $0["channelId"] as? String == "tvs.sbd.4000" }) {
                throw SubtitleError.message("error.download.appleTVPlusOnly")
            }
            throw SubtitleError.message("error.download.noITunesResource")
        }
        return result.sorted { $0.id < $1.id }
    }

    func tracks(for movie: MovieVersion, dsid: String = "") async throws -> [MovieSubtitleTrack] {
        let dsid = dsid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dsid.isEmpty || dsid.range(of: "^[0-9]+$", options: .regularExpression) != nil else {
            throw SubtitleError.message("error.download.invalidDSID")
        }
        var lastError: Error = SubtitleError.message("error.download.noPlaylist")
        var retry: [URL] = []
        for url in movie.manifests {
            do {
                let (content, base) = try await get(url)
                return try SubtitlePlaylist.tracks(content, baseURL: base)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                if let failure = error as? HTTPFailure, [401, 403, 404].contains(failure.status), Self.isAccountManifest(url), !dsid.isEmpty {
                    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "dsid", value: dsid)]
                    retry.append(parts.url!)
                }
            }
        }
        for url in retry {
            do {
                let (content, base) = try await get(url)
                return try SubtitlePlaylist.tracks(content, baseURL: base)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    func download(_ track: MovieSubtitleTrack, progress: @Sendable (Int, Int) async -> Void) async throws -> SubtitleDocument {
        var lastError: Error = SubtitleError.message("error.download.failed")
        for mirror in track.mirrors {
            do {
                let (playlist, base) = try await get(mirror)
                if playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") {
                    return try SubtitleDocument(text: playlist)
                }
                let segments = try SubtitlePlaylist.segments(playlist, baseURL: base)
                var texts = Array(repeating: "", count: segments.count)
                var completed = 0
                var bytes = 0
                try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    var next = 0
                    func enqueue(_ index: Int) {
                        group.addTask { (index, try await self.get(segments[index].url).0) }
                    }
                    while next < min(4, segments.count) { enqueue(next); next += 1 }
                    while let (index, text) = try await group.next() {
                        texts[index] = text
                        bytes += text.utf8.count
                        guard bytes <= 50_000_000 else { throw SubtitleError.message("error.download.sizeLimit") }
                        completed += 1
                        await progress(completed, segments.count)
                        if next < segments.count { enqueue(next); next += 1 }
                    }
                }
                return try SubtitlePlaylist.merge(texts, segments: segments)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }
}
