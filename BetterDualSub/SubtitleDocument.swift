import Foundation

nonisolated struct SubtitleItem: Equatable, Hashable, Sendable {
    let startMs: Int
    let endMs: Int
    let text: String
}

nonisolated enum SubtitleError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return subtitleLocalizedString(text) }
    }
}

nonisolated func subtitleSystemLanguage() -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
}

nonisolated func subtitleCurrentLanguage() -> String {
    switch UserDefaults.standard.string(forKey: "appLanguage") {
    case "zh-Hans": return "zh-Hans"
    case "en": return "en"
    default: return subtitleSystemLanguage()
    }
}

nonisolated func subtitleLocalizedString(_ key: String) -> String {
    guard let path = Bundle.main.path(forResource: subtitleCurrentLanguage(), ofType: "lproj"),
          let bundle = Bundle(path: path) else {
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}

nonisolated func subtitleLocalizedFormat(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: subtitleLocalizedString(format), locale: Locale(identifier: subtitleCurrentLanguage()), arguments: arguments)
}

nonisolated struct SubtitleDocument: Sendable {
    let items: [SubtitleItem]
    /// Running maximum of `endMs`, so lookups can stop scanning backwards once nothing earlier can still be active.
    private let prefixMaxEnd: [Int]

    init(items: [SubtitleItem], allowEmpty: Bool = false) throws {
        let valid = Set(items.filter { $0.startMs >= 0 && $0.endMs > $0.startMs && !$0.text.isEmpty })
        guard allowEmpty || !valid.isEmpty else { throw SubtitleError.message("error.subtitle.empty") }
        self.items = valid.sorted {
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
            return $0.text < $1.text
        }
        var running = 0
        prefixMaxEnd = self.items.map { running = max(running, $0.endMs); return running }
    }

    init(text: String) throws {
        self = try Self.parse(text).document
    }

    struct TimestampMap: Sendable {
        let localMs: Int
        let mpegMs: Double
    }

    static func parse(_ text: String, allowEmpty: Bool = false) throws -> (document: SubtitleDocument, map: TimestampMap?) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{feff}", with: "")
        var map: TimestampMap?
        if let line = normalized.components(separatedBy: "\n").first(where: { $0.hasPrefix("X-TIMESTAMP-MAP=") }) {
            let fields = line.dropFirst("X-TIMESTAMP-MAP=".count).split(separator: ",")
            let local = fields.first(where: { $0.hasPrefix("LOCAL:") }).flatMap { time(String($0.dropFirst(6))) }
            let mpeg = fields.first(where: { $0.hasPrefix("MPEGTS:") }).flatMap { Double($0.dropFirst(7)) }
            guard let local, let mpeg, mpeg.isFinite, mpeg >= 0, mpeg < 8_589_934_592 else {
                throw SubtitleError.message("error.subtitle.invalidTimeMap")
            }
            map = TimestampMap(localMs: local, mpegMs: mpeg / 90)
        }
        let separator = try NSRegularExpression(pattern: "\n[ \t]*\n+")
        let marked = separator.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "\u{0}")
        var items: [SubtitleItem] = []
        for block in marked.components(separatedBy: "\u{0}") {
            let lines = block.components(separatedBy: "\n")
            let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION" { continue }
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[index].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = time(timing[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = timing[1].split(whereSeparator: { $0.isWhitespace }).first,
                  let end = time(String(endToken)), end > start else {
                throw SubtitleError.message("error.subtitle.invalidTime")
            }
            let raw = lines.dropFirst(index + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { items.append(SubtitleItem(startMs: start, endMs: end, text: raw)) }
        }
        return (try SubtitleDocument(items: items, allowEmpty: allowEmpty), map)
    }

    static func time(_ value: String) -> Int? {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[parts.count - 2]), (0..<60).contains(minutes),
              let seconds = Double(parts[parts.count - 1]), seconds.isFinite, (0..<60).contains(seconds),
              let hours = parts.count == 3 ? Int(parts[0]) : 0, (0..<10_000).contains(hours) else { return nil }
        return Int((Double(hours * 3600 + minutes * 60) + seconds) * 1000.0 + 0.5)
    }

    /// End of the last cue, used as the length of the timeline in manual mode.
    var duration: Int { prefixMaxEnd.last ?? 0 }

    func text(at milliseconds: Int) -> String {
        // Binary search for the first item that starts after `milliseconds`.
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].startMs <= milliseconds { low = mid + 1 } else { high = mid }
        }
        var active: [String] = []
        var index = low - 1
        while index >= 0 && prefixMaxEnd[index] > milliseconds {
            if milliseconds < items[index].endMs { active.append(items[index].text) }
            index -= 1
        }
        return active.reversed().joined(separator: "\n")
    }

    var srt: String {
        items.enumerated().map { index, item in
            "\(index + 1)\n\(Self.timestamp(item.startMs)) --> \(Self.timestamp(item.endMs))\n\(item.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    /// Merges two tracks into one bilingual document: primary lines first, then secondary lines.
    /// Cue boundaries of the secondary track within `tolerance` ms of a primary boundary are snapped to it,
    /// and adjacent intervals with identical text are coalesced, so small timing differences between
    /// languages do not produce flickering single-language slivers.
    static func bilingual(primary: SubtitleDocument, secondary: SubtitleDocument, secondaryOffsetMs: Int = 0, tolerance: Int = 200) throws -> SubtitleDocument {
        let primaryItems = primary.items.compactMap { cleaned($0) }
        let anchors = Set(primaryItems.flatMap { [$0.startMs, $0.endMs] }).sorted()
        func snap(_ value: Int) -> Int {
            var low = 0, high = anchors.count
            while low < high {
                let mid = (low + high) / 2
                if anchors[mid] < value { low = mid + 1 } else { high = mid }
            }
            let nearest = [low - 1, low].filter { anchors.indices.contains($0) }.min { abs(anchors[$0] - value) < abs(anchors[$1] - value) }
            if let nearest, abs(anchors[nearest] - value) <= tolerance { return anchors[nearest] }
            return value
        }
        let secondaryItems = secondary.items.compactMap { cleaned($0) }.compactMap { item -> SubtitleItem? in
            let start = snap(max(0, item.startMs + secondaryOffsetMs)), end = snap(max(0, item.endMs + secondaryOffsetMs))
            return end > start ? SubtitleItem(startMs: start, endMs: end, text: item.text) : nil
        }
        let first = try SubtitleDocument(items: primaryItems, allowEmpty: true)
        let second = try SubtitleDocument(items: secondaryItems, allowEmpty: true)
        let bounds = Set((first.items + second.items).flatMap { [$0.startMs, $0.endMs] }).sorted()
        var merged: [SubtitleItem] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            let text = [first.text(at: start), second.text(at: start)].filter { !$0.isEmpty }.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            if let last = merged.last, last.endMs == start, last.text == text {
                merged[merged.count - 1] = SubtitleItem(startMs: last.startMs, endMs: end, text: text)
            } else {
                merged.append(SubtitleItem(startMs: start, endMs: end, text: text))
            }
        }
        return try SubtitleDocument(items: merged)
    }

    /// Strips WebVTT-only markup (keeping b/i/u), decodes common entities and trims each line for plain SRT output.
    private static func cleaned(_ item: SubtitleItem) -> SubtitleItem? {
        let tags = try! NSRegularExpression(pattern: "<(?!/?(?:b|i|u)\\s*>)[^>]*>", options: .caseInsensitive)
        var text = tags.stringByReplacingMatches(in: item.text, range: NSRange(item.text.startIndex..., in: item.text), withTemplate: "")
        for (entity, value) in [("&lrm;", ""), ("&rlm;", ""), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : SubtitleItem(startMs: item.startMs, endMs: item.endMs, text: text)
    }

    private static func timestamp(_ value: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, value % 1000)
    }

    static func displayHTML(_ text: String) -> String {
        // Preserve basic subtitle emphasis without loading HTML images or other resources.
        let tags = try! NSRegularExpression(pattern: "<(?!/?(?:b|i|u)\\s*>|br\\s*/?>)[^>]*>", options: .caseInsensitive)
        return tags.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// How a track's cue text is laid out: as authored, forced onto one line, or at most two balanced lines.
nonisolated enum SubtitleLineMode: String, CaseIterable, Sendable {
    case original, single, double

    static let defaultValue = SubtitleLineMode.original

    /// Terminal width of a line, counting CJK characters double.
    private static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6: true
        default: false
        }
    }

    /// Joins two lines, with a space unless the seam is between CJK characters.
    private static func join(_ a: String, _ b: String) -> String {
        guard let last = a.unicodeScalars.last, let first = b.unicodeScalars.first else { return a + b }
        return isWide(last) || isWide(first) ? a + b : a + " " + b
    }

    private static func merged(_ lines: [String]) -> String {
        lines.dropFirst().reduce(lines.first ?? "") { join($0, $1) }
    }

    /// Splits `words` (tokens separated by spaces, or single CJK characters) near the visual middle.
    private static func balancedSplit(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            let wide = character.unicodeScalars.first.map(isWide) ?? false
            if character == " " {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else if wide {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(character))
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard tokens.count > 1 else { return [text] }
        let total = width(text)
        var best = 1, bestDiff = Int.max, running = 0
        for index in 1..<tokens.count {
            running += width(tokens[index - 1]) + 1
            let diff = abs(total - running * 2)
            if diff < bestDiff { bestDiff = diff; best = index }
        }
        let first = tokens[..<best].reduce("") { join($0, $1) }
        let second = tokens[best...].reduce("") { join($0, $1) }
        return [first, second]
    }

    func apply(to text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count > 0 else { return text }
        switch self {
        case .original:
            return text
        case .single:
            return Self.merged(lines)
        case .double:
            if lines.count == 1 {
                // Short lines stay as they are; long ones are split in half.
                return Self.width(lines[0]) > 44 ? Self.balancedSplit(lines[0]).joined(separator: "\n") : lines[0]
            }
            if lines.count == 2 { return lines.joined(separator: "\n") }
            return Self.balancedSplit(Self.merged(lines)).joined(separator: "\n")
        }
    }
}

nonisolated struct SubtitleClock {
    var positionMs: Double = 0
    var uptime: TimeInterval = 0
    var rate: Double = 0
    var valid = false

    func position(at now: TimeInterval) -> Int {
        Int(max(0, positionMs + max(0, now - uptime) * 1000 * rate))
    }

    /// Moves the anchor to `now` without changing the position, so rate changes and pauses stay continuous.
    mutating func rebase(at now: TimeInterval) {
        positionMs = Double(position(at: now))
        uptime = now
    }
}

nonisolated enum SubtitleFileReader {
    static let maximumBytes = 20 * 1024 * 1024

    /// Reads a local .srt/.vtt file, detecting common encodings (BOM, UTF-8, then legacy CJK code pages).
    static func document(at url: URL) throws -> SubtitleDocument {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw SubtitleError.message("error.subtitle.unreadable") }
        guard data.count <= maximumBytes else { throw SubtitleError.message("error.subtitle.tooLarge") }
        return try SubtitleDocument(text: decode(data))
    }

    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        let legacy: [CFStringEncodings] = [.GB_18030_2000, .big5, .shiftJIS, .EUC_KR]
        let encodings = legacy.map { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0.rawValue))) }
        for encoding in encodings + [.windowsCP1252] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw SubtitleError.message("error.subtitle.unreadable")
    }

    /// Reads a delay hint such as "Movie (-1500ms).srt".
    static func delayHint(in url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let match = name.range(of: #"\((-?\d+)ms\)$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(name[match].dropFirst().dropLast(3))
    }
}
