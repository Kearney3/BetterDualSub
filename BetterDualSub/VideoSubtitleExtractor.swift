import Foundation
import AVFoundation
import CoreMedia

/// A text subtitle track muxed into a video file.
nonisolated struct VideoSubtitleStream: Sendable {
    enum Container: Sendable { case matroska, mpeg4 }
    enum Format: Sendable { case plain, subStation, webVTTSamples }

    let file: URL
    let container: Container
    /// Matroska TrackNumber, or MP4 track ID.
    let trackNumber: Int
    let format: Format
    /// Matroska content encodings to undo on every block, applied in this order.
    let encodings: [MatroskaContentEncoding]
}

nonisolated struct MatroskaContentEncoding: Sendable {
    enum Kind: Sendable { case zlib, headerStripping(Data) }
    let kind: Kind
}

/// Reads text subtitle tracks embedded in Matroska (.mkv, .webm) and MPEG-4 (.mp4, .m4v, .mov) files. Matroska is
/// parsed here, reading only element headers and subtitle blocks; MPEG-4 goes through AVFoundation. Image-based
/// subtitles (PGS, VobSub, DVB) have no text and are left out.
nonisolated enum VideoSubtitleExtractor {
    static let matroskaExtensions = ["mkv", "mks", "webm"]
    static let mpeg4Extensions = ["mp4", "m4v", "mov"]
    static var fileExtensions: [String] { matroskaExtensions + mpeg4Extensions }
    // Match the subtitle parser's 10,000-hour bound.
    private static let maximumTimelineMs: Int64 = 36_000_000_000

    @concurrent static func inspect(_ url: URL) async throws -> [LocalSubtitleTrack] {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let tracks: [LocalSubtitleTrack]
        switch file.pathExtension.lowercased() {
        case let ext where matroskaExtensions.contains(ext): tracks = try MatroskaFile(url: file).subtitleTracks()
        case let ext where mpeg4Extensions.contains(ext): tracks = try await MPEG4Subtitles.tracks(in: file)
        default: throw SubtitleError.message("error.video.notSelected")
        }
        return LocalSubtitleTrack.sortedForPicking(tracks)
    }

    /// Extracts `tracks`, which all come from one file; tracks without any cue are left out. A Matroska file is read
    /// once for all of them.
    @concurrent static func documents(for tracks: [LocalSubtitleTrack]) async throws -> [String: SubtitleDocument] {
        let streams = tracks.compactMap { track -> (String, VideoSubtitleStream)? in
            guard case .video(let stream) = track.source else { return nil }
            return (track.id, stream)
        }
        guard let first = streams.first?.1 else { return [:] }
        var cues: [String: [SubtitleItem]] = [:]
        switch first.container {
        case .matroska:
            let byNumber = try MatroskaFile(url: first.file).cues(for: streams.map(\.1))
            for (id, stream) in streams { cues[id] = byNumber[stream.trackNumber] ?? [] }
        case .mpeg4:
            for (id, stream) in streams { cues[id] = try await MPEG4Subtitles.cues(for: stream) }
        }
        return try cues.compactMapValues { cues in
            let document = try SubtitleDocument(items: cues, allowEmpty: true)
            return document.items.isEmpty ? nil : document
        }
    }

    static func language(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "und" }
        // Matroska and QuickTime store ISO 639-2; its bibliographic codes have no two-letter equivalent in Locale.
        let terminology = ["alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld",
                           "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri",
                           "may": "msa", "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym"]
        let parts = code.split(separator: "-", maxSplits: 1).map(String.init)
        let base = terminology[parts[0].lowercased()] ?? parts[0]
        let short = Locale.LanguageCode(base).identifier(.alpha2) ?? base
        return ([short] + parts.dropFirst()).joined(separator: "-")
    }

    static func mpeg4SampleText(_ sample: Data, format: VideoSubtitleStream.Format) -> String {
        MPEG4Subtitles.sampleText(sample, format: format)
    }

    static func displayName(_ language: String) -> String {
        Locale(identifier: subtitleCurrentLanguage()).localizedString(forIdentifier: language) ?? language
    }

    /// Cue text of one subtitle frame.
    static func text(_ data: Data, format: VideoSubtitleStream.Format) -> String {
        var raw = String(data: data, encoding: .utf8) ?? (try? SubtitleFileReader.decode(data)) ?? ""
        while raw.hasSuffix("\0") { raw.removeLast() }
        switch format {
        case .subStation:
            // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text: the text may contain commas.
            let fields = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            return SubtitleDocument.subStationText(fields.count == 9 ? String(fields[8]) : raw)
        case .plain, .webVTTSamples:
            return raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{feff}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Milliseconds of `units` × `scale` nanoseconds, or nil outside the subtitle timeline.
    static func milliseconds(_ units: Int64, scale: Int64) -> Int? {
        let (product, overflow) = units.multipliedReportingOverflow(by: scale)
        guard !overflow, product >= 0 else { return nil }
        let ms = product / 1_000_000
        return ms < maximumTimelineMs ? Int(ms) : nil
    }

    /// Frames without a duration last until the next one, up to a few seconds.
    static func closeOpenCues(_ cues: [(start: Int, end: Int?, text: String)]) -> [SubtitleItem] {
        let sorted = cues.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        return sorted.enumerated().compactMap { index, cue in
            guard !cue.text.isEmpty else { return nil }
            let next = sorted[(index + 1)...].first { $0.start > cue.start }?.start
            let end = cue.end ?? min(next ?? cue.start + 3000, cue.start + 5000)
            return end > cue.start ? SubtitleItem(startMs: cue.start, endMs: end, text: cue.text) : nil
        }
    }
}

// MARK: Matroska

private nonisolated struct MatroskaTrack {
    var number = 0
    var type = 0
    var codec = ""
    var name = ""
    var language = "eng"
    var languageBCP47: String?
    var forced = false
    var hearingImpaired = false
    var encodings: [(order: UInt64, scope: UInt64, type: UInt64, algorithm: UInt64, settings: Data)] = []

    static let subtitleType = 0x11

    var format: VideoSubtitleStream.Format? {
        switch codec {
        case "S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/WEBVTT": .plain
        case "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA": .subStation
        default: nil
        }
    }

    /// The decoding steps for each frame, or nil when a frame encoding cannot be undone (encryption, bzlib, lzo).
    var frameEncodings: [MatroskaContentEncoding]? {
        var steps: [MatroskaContentEncoding] = []
        // Decoding starts from the encoding applied last, the highest order.
        for encoding in encodings.sorted(by: { $0.order > $1.order }) where encoding.scope & 1 != 0 {
            guard encoding.type == 0 else { return nil }
            switch encoding.algorithm {
            case 0: steps.append(MatroskaContentEncoding(kind: .zlib))
            case 3: steps.append(MatroskaContentEncoding(kind: .headerStripping(encoding.settings)))
            default: return nil
            }
        }
        return steps
    }
}

private nonisolated final class MatroskaFile {
    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3, docType: UInt32 = 0x4282
        static let segment: UInt32 = 0x1853_8067, seekHead: UInt32 = 0x114D_9B74, seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966, timestampScale: UInt32 = 0x2A_D7B1
        static let tracks: UInt32 = 0x1654_AE6B, trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7, trackType: UInt32 = 0x83, codecID: UInt32 = 0x86, name: UInt32 = 0x536E
        static let language: UInt32 = 0x22_B59C, languageBCP47: UInt32 = 0x22_B59D
        static let flagForced: UInt32 = 0x55AA, flagHearingImpaired: UInt32 = 0x55AB
        static let contentEncodings: UInt32 = 0x6D80, contentEncoding: UInt32 = 0x6240
        static let encodingOrder: UInt32 = 0x5031, encodingScope: UInt32 = 0x5032, encodingType: UInt32 = 0x5033
        static let compression: UInt32 = 0x5034, compressionAlgorithm: UInt32 = 0x4254, compressionSettings: UInt32 = 0x4255
        static let cluster: UInt32 = 0x1F43_B675, timestamp: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0, block: UInt32 = 0xA1, blockDuration: UInt32 = 0x9B
        /// Children of a Segment: they end a Cluster of unknown size.
        static let level1: Set<UInt32> = [seekHead, info, tracks, cluster, 0x1C53_BB6B, 0x1941_A469, 0x1043_A770, 0x1254_C367]
    }

    private let reader: EBMLReader
    private var timestampScale: Int64 = 1_000_000
    private var segmentEnd: Int64 = 0
    private var firstCluster: Int64?
    private var tracks: [MatroskaTrack] = []
    private let url: URL

    init(url: URL) throws {
        self.url = url
        do { reader = try EBMLReader(url: url) }
        catch { throw SubtitleError.message("error.video.unreadable") }
        do { try readHeaders() }
        catch is EBMLReader.Failure { throw SubtitleError.message("error.video.invalid") }
    }

    func subtitleTracks() throws -> [LocalSubtitleTrack] {
        let subtitles = tracks.filter { $0.type == MatroskaTrack.subtitleType }
        let readable = subtitles.compactMap { track -> LocalSubtitleTrack? in
            guard let format = track.format, let encodings = track.frameEncodings else { return nil }
            let language = VideoSubtitleExtractor.language(track.languageBCP47 ?? track.language)
            let lowercasedName = track.name.lowercased()
            return LocalSubtitleTrack(id: "mkv:\(track.number)", language: language,
                                      name: track.name.isEmpty ? VideoSubtitleExtractor.displayName(language) : track.name,
                                      forced: track.forced || lowercasedName.contains("forced"),
                                      sdh: track.hearingImpaired || lowercasedName.contains("sdh"),
                                      source: .video(VideoSubtitleStream(file: url, container: .matroska, trackNumber: track.number,
                                                                         format: format, encodings: encodings)))
        }
        guard !readable.isEmpty else {
            throw SubtitleError.message(subtitles.isEmpty ? "error.video.noTracks" : "error.video.noTextTracks")
        }
        return readable
    }

    /// Cues of each of `streams`, by track number, from one pass over the Clusters. A file cut short (still
    /// downloading, say) gives the cues up to where it ends.
    func cues(for streams: [VideoSubtitleStream]) throws -> [Int: [SubtitleItem]] {
        let wanted = Dictionary(streams.map { ($0.trackNumber, $0) }, uniquingKeysWith: { first, _ in first })
        var cues: [Int: [(start: Int, end: Int?, text: String)]] = [:]
        if let firstCluster {
            reader.seek(to: firstCluster)
            do {
                while reader.position < segmentEnd {
                    try Task.checkCancellation()
                    guard let element = try reader.element() else { break }
                    if element.id == ID.cluster {
                        try readCluster(element, wanted: wanted, into: &cues)
                    } else {
                        guard let end = element.end else { break }
                        reader.seek(to: end)
                    }
                }
            } catch is EBMLReader.Failure {}
        }
        return cues.mapValues { VideoSubtitleExtractor.closeOpenCues($0) }
    }

    private func readHeaders() throws {
        guard let header = try reader.element(), header.id == ID.ebml, let headerEnd = header.end else {
            throw EBMLReader.Failure.invalid
        }
        var docType = "matroska"
        try reader.children(until: headerEnd) { if $0.id == ID.docType { docType = try reader.string($0) } }
        guard ["matroska", "webm"].contains(docType) else { throw EBMLReader.Failure.invalid }
        reader.seek(to: headerEnd)
        var segment = try reader.element()
        while let element = segment, element.id != ID.segment {
            guard let end = element.end else { throw EBMLReader.Failure.invalid }
            reader.seek(to: end)
            segment = try reader.element()
        }
        guard let segment else { throw EBMLReader.Failure.invalid }
        let segmentStart = reader.position
        segmentEnd = min(segment.end ?? reader.size, reader.size)
        var seeks: [UInt32: Int64] = [:]
        var foundInfo = false, foundTracks = false
        while reader.position < segmentEnd, !(foundTracks && firstCluster != nil) {
            guard let element = try reader.element() else { break }
            switch element.id {
            case ID.seekHead: seeks.merge(try readSeekHead(element, segmentStart: segmentStart)) { first, _ in first }
            case ID.info: try readInfo(element); foundInfo = true
            case ID.tracks: try readTracks(element); foundTracks = true
            case ID.cluster:
                firstCluster = element.start
                // Tracks normally precede the Clusters; otherwise the SeekHead says where they are.
                if !foundTracks, let position = seeks[ID.tracks] {
                    if !foundInfo, let infoPosition = seeks[ID.info] {
                        reader.seek(to: infoPosition)
                        if let info = try reader.element(), info.id == ID.info { try readInfo(info) }
                    }
                    reader.seek(to: position)
                    if let tracks = try reader.element(), tracks.id == ID.tracks { try readTracks(tracks); foundTracks = true }
                }
                guard foundTracks else { throw EBMLReader.Failure.invalid }
                continue
            default: break
            }
            guard let end = element.end else { throw EBMLReader.Failure.invalid }
            reader.seek(to: end)
        }
        guard foundTracks else { throw EBMLReader.Failure.invalid }
    }

    private func readSeekHead(_ element: EBMLReader.Element, segmentStart: Int64) throws -> [UInt32: Int64] {
        var seeks: [UInt32: Int64] = [:]
        try reader.children(of: element) { seek in
            guard seek.id == ID.seek else { return }
            var id: UInt32?, position: Int64?
            try reader.children(of: seek) { field in
                switch field.id {
                case ID.seekID: id = UInt32(truncatingIfNeeded: try reader.unsigned(field))
                case ID.seekPosition: position = Int64(exactly: try reader.unsigned(field))
                default: break
                }
            }
            if let id, let position, position < reader.size - segmentStart { seeks[id] = segmentStart + position }
        }
        return seeks
    }

    private func readInfo(_ element: EBMLReader.Element) throws {
        try reader.children(of: element) { field in
            if field.id == ID.timestampScale, let scale = Int64(exactly: try reader.unsigned(field)), scale > 0 {
                timestampScale = scale
            }
        }
    }

    private func readTracks(_ element: EBMLReader.Element) throws {
        try reader.children(of: element) { entry in
            guard entry.id == ID.trackEntry else { return }
            var track = MatroskaTrack()
            try reader.children(of: entry) { field in
                switch field.id {
                case ID.trackNumber: track.number = Int(clamping: try reader.unsigned(field))
                case ID.trackType: track.type = Int(clamping: try reader.unsigned(field))
                case ID.codecID: track.codec = try reader.string(field)
                case ID.name: track.name = try reader.string(field)
                case ID.language: track.language = try reader.string(field)
                case ID.languageBCP47: track.languageBCP47 = try reader.string(field)
                case ID.flagForced: track.forced = try reader.unsigned(field) != 0
                case ID.flagHearingImpaired: track.hearingImpaired = try reader.unsigned(field) != 0
                case ID.contentEncodings: try readEncodings(field, into: &track)
                default: break
                }
            }
            if track.number > 0 { tracks.append(track) }
        }
    }

    private func readEncodings(_ element: EBMLReader.Element, into track: inout MatroskaTrack) throws {
        try reader.children(of: element) { item in
            guard item.id == ID.contentEncoding else { return }
            var encoding: (order: UInt64, scope: UInt64, type: UInt64, algorithm: UInt64, settings: Data) = (0, 1, 0, 0, Data())
            try reader.children(of: item) { field in
                switch field.id {
                case ID.encodingOrder: encoding.order = try reader.unsigned(field)
                case ID.encodingScope: encoding.scope = try reader.unsigned(field)
                case ID.encodingType: encoding.type = try reader.unsigned(field)
                case ID.compression:
                    try reader.children(of: field) { setting in
                        switch setting.id {
                        case ID.compressionAlgorithm: encoding.algorithm = try reader.unsigned(setting)
                        case ID.compressionSettings: encoding.settings = try reader.data(setting)
                        default: break
                        }
                    }
                default: break
                }
            }
            track.encodings.append(encoding)
        }
    }

    private func readCluster(_ cluster: EBMLReader.Element, wanted: [Int: VideoSubtitleStream],
                             into cues: inout [Int: [(start: Int, end: Int?, text: String)]]) throws {
        let end = cluster.end.map { min($0, segmentEnd) } ?? segmentEnd
        var clusterTime: Int64 = 0
        while reader.position < end {
            let start = reader.position
            guard let element = try reader.element() else { return }
            // A Cluster of unknown size ends where the next Segment child begins.
            if cluster.end == nil, ID.level1.contains(element.id) { reader.seek(to: start); return }
            guard let elementEnd = element.end, elementEnd <= end else { throw EBMLReader.Failure.invalid }
            switch element.id {
            case ID.timestamp: clusterTime = Int64(clamping: try reader.unsigned(element))
            case ID.simpleBlock:
                if let block = try readBlock(until: elementEnd, wanted: wanted) {
                    append(block, duration: nil, clusterTime: clusterTime, wanted: wanted, into: &cues)
                }
            case ID.blockGroup:
                var block: (track: Int, relative: Int64, payload: Data)?
                var duration: Int64?
                try reader.children(of: element) { field in
                    switch field.id {
                    case ID.block: block = try readBlock(until: field.end ?? elementEnd, wanted: wanted)
                    case ID.blockDuration: duration = Int64(exactly: try reader.unsigned(field))
                    default: break
                    }
                }
                if let block { append(block, duration: duration, clusterTime: clusterTime, wanted: wanted, into: &cues) }
            default: break
            }
            reader.seek(to: elementEnd)
        }
    }

    /// Reads a Block of a wanted track; other tracks' blocks (all the video and audio) are skipped unread.
    private func readBlock(until end: Int64, wanted: [Int: VideoSubtitleStream]) throws -> (track: Int, relative: Int64, payload: Data)? {
        guard let number = try reader.vint(), let stream = wanted[Int(clamping: number)] else { return nil }
        let timecode = try reader.bytes(2)
        let relative = Int64(Int16(bitPattern: UInt16(timecode[0]) << 8 | UInt16(timecode[1])))
        let flags = try reader.byte()
        // Subtitle frames are not laced in practice; a laced block would need splitting first.
        let length = end - reader.position
        guard flags & 0x06 == 0, (0...1_000_000).contains(length) else { return nil }
        var payload = Data(try reader.bytes(Int(length)))
        for encoding in stream.encodings {
            switch encoding.kind {
            case .zlib:
                // Matroska stores zlib streams; the Compression framework reads the raw deflate data after the header.
                guard payload.count > 2,
                      let inflated = try? (Data(payload.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data else { return nil }
                payload = inflated
            case .headerStripping(let header): payload = header + payload
            }
        }
        return (stream.trackNumber, relative, payload)
    }

    private func append(_ block: (track: Int, relative: Int64, payload: Data), duration: Int64?, clusterTime: Int64,
                        wanted: [Int: VideoSubtitleStream], into cues: inout [Int: [(start: Int, end: Int?, text: String)]]) {
        guard let stream = wanted[block.track],
              let start = VideoSubtitleExtractor.milliseconds(clusterTime &+ block.relative, scale: timestampScale) else { return }
        let end = duration.flatMap { VideoSubtitleExtractor.milliseconds(clusterTime &+ block.relative &+ $0, scale: timestampScale) }
        cues[block.track, default: []].append((start, end, VideoSubtitleExtractor.text(block.payload, format: stream.format)))
    }
}

/// Buffered reading of EBML elements, so skipping a large video frame costs a seek rather than a read.
private nonisolated final class EBMLReader {
    enum Failure: Error { case endOfFile, invalid }

    struct Element {
        let id: UInt32
        /// Offset of the element's ID.
        let start: Int64
        /// Offset just past its data; nil for an element of unknown size.
        let end: Int64?
    }

    let size: Int64
    private(set) var position: Int64 = 0
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var bufferStart: Int64 = 0
    private static let chunkSize = 1 << 16

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int64(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    func seek(to offset: Int64) { position = offset }

    func byte() throws -> UInt8 {
        try fillIfNeeded()
        defer { position += 1 }
        return buffer[Int(position - bufferStart)]
    }

    func bytes(_ count: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            try fillIfNeeded()
            let offset = Int(position - bufferStart)
            let length = min(count - result.count, buffer.count - offset)
            result.append(contentsOf: buffer[offset..<(offset + length)])
            position += Int64(length)
        }
        return result
    }

    private func fillIfNeeded() throws {
        guard position < bufferStart || position >= bufferStart + Int64(buffer.count) else { return }
        guard position >= 0, position < size else { throw Failure.endOfFile }
        try handle.seek(toOffset: UInt64(position))
        buffer = [UInt8](try handle.read(upToCount: Self.chunkSize) ?? Data())
        bufferStart = position
        guard !buffer.isEmpty else { throw Failure.endOfFile }
    }

    /// The element header at the current position, leaving the position at its data; nil at the end of the file.
    func element() throws -> Element? {
        guard position < size else { return nil }
        let start = position
        let first = try byte()
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4 else { throw Failure.invalid }
        var id = UInt32(first)
        for _ in 1..<idLength { id = id << 8 | UInt32(try byte()) }
        guard let length = try vint(allowUnknown: true) else { return Element(id: id, start: start, end: nil) }
        // An element may run past the end of the file: a cut-off download is still read up to where it stops.
        guard let dataLength = Int64(exactly: length), dataLength <= Int64.max - position else { throw Failure.invalid }
        return Element(id: id, start: start, end: position + dataLength)
    }

    /// A variable-length integer with its length marker removed; nil when all its bits are set (unknown size).
    func vint(allowUnknown: Bool = false) throws -> UInt64? {
        let first = try byte()
        let length = first.leadingZeroBitCount + 1
        guard length <= 8 else { throw Failure.invalid }
        var value = UInt64(first & (0xFF >> length))
        var allOnes = value == UInt64(0xFF >> length)
        for _ in 1..<length {
            let next = try byte()
            allOnes = allOnes && next == 0xFF
            value = value << 8 | UInt64(next)
        }
        return allowUnknown && allOnes ? nil : value
    }

    func children(of element: Element, _ body: (Element) throws -> Void) throws {
        guard let end = element.end else { throw Failure.invalid }
        try children(until: end, body)
    }

    func children(until end: Int64, _ body: (Element) throws -> Void) throws {
        while position < end {
            guard let child = try element() else { return }
            guard let childEnd = child.end, childEnd <= end else { throw Failure.invalid }
            try body(child)
            seek(to: childEnd)
        }
    }

    func unsigned(_ element: Element) throws -> UInt64 {
        let data = try payload(element, limit: 8)
        return data.reduce(0) { $0 << 8 | UInt64($1) }
    }

    func string(_ element: Element) throws -> String {
        let data = try payload(element, limit: 4096)
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    func data(_ element: Element) throws -> Data {
        Data(try payload(element, limit: 1_000_000))
    }

    private func payload(_ element: Element, limit: Int64) throws -> [UInt8] {
        guard let end = element.end, end - position <= limit else { throw Failure.invalid }
        return try bytes(Int(end - position))
    }
}

// MARK: MPEG-4

private nonisolated enum MPEG4Subtitles {
    static func tracks(in url: URL) async throws -> [LocalSubtitleTrack] {
        let asset = AVURLAsset(url: url)
        let candidates: [AVAssetTrack]
        do {
            candidates = try await asset.loadTracks(withMediaType: .subtitle) + asset.loadTracks(withMediaType: .text)
        } catch { throw SubtitleError.message("error.video.invalid") }
        var tracks: [LocalSubtitleTrack] = []
        for track in candidates {
            try Task.checkCancellation()
            let (formats, code, tag, characteristics, metadata) = try await track.load(
                .formatDescriptions, .languageCode, .extendedLanguageTag, .mediaCharacteristics, .metadata)
            guard let subtype = formats.first.map(CMFormatDescriptionGetMediaSubType),
                  let format = format(subtype) else { continue }
            let language = VideoSubtitleExtractor.language(tag ?? code)
            var name: String?
            for item in metadata where item.identifier == .quickTimeUserDataTrackName || item.commonKey == .commonKeyTitle {
                name = try await item.load(.stringValue)
                if name?.isEmpty == false { break }
            }
            tracks.append(LocalSubtitleTrack(
                id: "mp4:\(track.trackID)", language: language,
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? VideoSubtitleExtractor.displayName(language),
                forced: characteristics.contains(.containsOnlyForcedSubtitles),
                sdh: characteristics.contains(.transcribesSpokenDialogForAccessibility)
                    || characteristics.contains(.describesMusicAndSoundForAccessibility),
                source: .video(VideoSubtitleStream(file: url, container: .mpeg4, trackNumber: Int(track.trackID),
                                                   format: format, encodings: []))))
        }
        guard !tracks.isEmpty else {
            throw SubtitleError.message(candidates.isEmpty ? "error.video.noTracks" : "error.video.noTextTracks")
        }
        return tracks
    }

    private static func format(_ subtype: FourCharCode) -> VideoSubtitleStream.Format? {
        switch subtype {
        case kCMTextFormatType_3GText, kCMTextFormatType_QTText: .plain
        case kCMSubtitleFormatType_WebVTT: .webVTTSamples
        default: nil
        }
    }

    static func cues(for stream: VideoSubtitleStream) async throws -> [SubtitleItem] {
        let asset = AVURLAsset(url: stream.file)
        guard let track = try await asset.loadTrack(withTrackID: CMPersistentTrackID(stream.trackNumber)) else {
            throw SubtitleError.message("error.video.invalid")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SubtitleError.message("error.video.invalid") }
        reader.add(output)
        guard reader.startReading() else { throw SubtitleError.message("error.video.unreadable") }
        defer { reader.cancelReading() }
        var cues: [(start: Int, end: Int?, text: String)] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            guard data.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count,
                                                                           destination: $0.baseAddress!) }) == noErr else { continue }
            var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: CMSampleBufferGetNumSamples(buffer))
            var sizes = [Int](repeating: 0, count: timings.count)
            guard !timings.isEmpty,
                  CMSampleBufferGetOutputSampleTimingInfoArray(buffer, entryCount: timings.count, arrayToFill: &timings,
                                                               entriesNeededOut: nil) == noErr else { continue }
            if CMSampleBufferGetSampleSizeArray(buffer, entryCount: sizes.count, arrayToFill: &sizes, entriesNeededOut: nil) != noErr {
                sizes = timings.count == 1 ? [data.count] : []
            }
            var offset = 0
            for (timing, size) in zip(timings, sizes) {
                defer { offset += size }
                guard size > 0, offset + size <= data.count,
                      let start = milliseconds(timing.presentationTimeStamp) else { continue }
                let text = sampleText(data.subdata(in: offset..<(offset + size)), format: stream.format)
                cues.append((start, milliseconds(timing.presentationTimeStamp + timing.duration), text))
            }
        }
        if reader.status == .failed { throw SubtitleError.message("error.video.unreadable") }
        return VideoSubtitleExtractor.closeOpenCues(cues)
    }

    private static func milliseconds(_ time: CMTime) -> Int? {
        guard time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds >= 0 && seconds < 36_000_000 ? Int((seconds * 1000).rounded()) : nil
    }

    /// 3GPP / QuickTime text samples start with a 16-bit text length; WebVTT samples are boxes with a 'payl' cue text.
    static func sampleText(_ sample: Data, format: VideoSubtitleStream.Format) -> String {
        let bytes = [UInt8](sample)
        switch format {
        case .webVTTSamples:
            var lines: [String] = []
            func boxes(_ range: Range<Int>) {
                var offset = range.lowerBound
                while offset + 8 <= range.upperBound {
                    let size = Int(bytes[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                    let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
                    guard size >= 8, offset + size <= range.upperBound else { return }
                    if type == "vttc" { boxes((offset + 8)..<(offset + size)) }
                    if type == "payl" {
                        lines.append(VideoSubtitleExtractor.text(Data(bytes[(offset + 8)..<(offset + size)]), format: .plain))
                    }
                    offset += size
                }
            }
            boxes(0..<bytes.count)
            return lines.filter { !$0.isEmpty }.joined(separator: "\n")
        case .plain, .subStation:
            guard bytes.count >= 2 else { return "" }
            let length = min(Int(bytes[0]) << 8 | Int(bytes[1]), bytes.count - 2)
            let text = Data(bytes[2..<(2 + length)])
            if text.starts(with: [0xFE, 0xFF]) || text.starts(with: [0xFF, 0xFE]), let utf16 = String(data: text, encoding: .utf16) {
                return VideoSubtitleExtractor.text(Data(utf16.utf8), format: .plain)
            }
            return VideoSubtitleExtractor.text(text, format: .plain)
        }
    }
}
