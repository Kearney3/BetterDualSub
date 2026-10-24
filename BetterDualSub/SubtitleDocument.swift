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
    /// Every cue start and end, sorted: the moments the text on screen can change.
    private let boundaries: [Int]

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
        boundaries = Set(self.items.flatMap { [$0.startMs, $0.endMs] }).sorted()
    }

    init(text: String) throws {
        self = try Self.isSubStationAlpha(text) ? Self.parseSubStationAlpha(text) : Self.parse(text).document
    }

    /// Advanced SubStation Alpha (.ass) and SubStation Alpha (.ssa) files keep their lines in an [Events] section.
    static func isSubStationAlpha(_ text: String) -> Bool {
        text.range(of: #"(?im)^[ \t]*\[(Script Info|Events)\][ \t]*$"#, options: .regularExpression) != nil
    }

    /// Reads the Dialogue lines of an .ass / .ssa file: their timing and text, without styling or positioning.
    /// Bilingual files that put each language on its own Dialogue line show both lines together.
    static func parseSubStationAlpha(_ text: String, allowEmpty: Bool = false) throws -> SubtitleDocument {
        // SSA v4 names its first column Marked instead of Layer; files without a Format line use the ASS default.
        var columns = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = false
        var items: [SubtitleItem] = []
        let lines = text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents, let colon = line.firstIndex(of: ":") else { continue }
            let kind = line[..<colon].lowercased()
            let body = line[line.index(after: colon)...]
            if kind == "format" {
                columns = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            // Comment lines are disabled dialogue; Picture, Sound and Command events carry no text.
            guard kind == "dialogue",
                  let startColumn = columns.firstIndex(of: "start"), let endColumn = columns.firstIndex(of: "end"),
                  let textColumn = columns.firstIndex(of: "text"), textColumn == columns.count - 1 else { continue }
            // The text is the last column and may itself contain commas.
            let values = body.split(separator: ",", maxSplits: columns.count - 1, omittingEmptySubsequences: false)
            guard values.count == columns.count else { continue }
            guard let start = time(values[startColumn].trimmingCharacters(in: .whitespaces)),
                  let end = time(values[endColumn].trimmingCharacters(in: .whitespaces)) else {
                throw SubtitleError.message("error.subtitle.invalidTime")
            }
            let cueText = subStationText(String(values[textColumn]))
            if end > start, !cueText.isEmpty { items.append(SubtitleItem(startMs: start, endMs: end, text: cueText)) }
        }
        return try SubtitleDocument(items: items, allowEmpty: allowEmpty)
    }

    /// Plain text of a Dialogue line: override blocks such as {\i1} or {\pos(…)} removed, \N as a line break,
    /// \h as a space. Vector drawings ({\p1}…) are not text and come back empty.
    static func subStationText(_ text: String) -> String {
        guard text.range(of: #"\{[^}]*\\p[1-9]"#, options: .regularExpression) == nil else { return "" }
        let plain = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\h", with: " ")
        return plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
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

    /// The first cue start or end after `milliseconds`, when `text(at:)` next changes; nil after the last cue.
    func nextChange(after milliseconds: Int) -> Int? {
        var low = 0, high = boundaries.count
        while low < high {
            let mid = (low + high) / 2
            if boundaries[mid] <= milliseconds { low = mid + 1 } else { high = mid }
        }
        return low < boundaries.count ? boundaries[low] : nil
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

}

/// A stretch of cue text with one set of emphasis attributes.
nonisolated struct SubtitleTextRun: Equatable, Sendable {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    /// "#RRGGBB" from a font color, a WebVTT color class or an ASS override; nil uses the track's color.
    var color: String?

    func sameStyle(as other: SubtitleTextRun) -> Bool {
        bold == other.bold && italic == other.italic && underline == other.underline
            && strikethrough == other.strikethrough && color == other.color
    }
}

/// Reads the markup found in subtitle cues without an HTML engine: b/i/u/s and font color tags, WebVTT voice, class,
/// language, ruby and timestamp tags, ASS override blocks left in SRT files ({\an8}, {\i1}, {\c&H00FFFF&}) and
/// character entities. Anything else that looks like a tag is dropped; a lone "<" stays as text.
nonisolated enum SubtitleMarkup {
    private struct State {
        var bold = 0, italic = 0, underline = 0, strikethrough = 0
        var colors: [String?] = []
        /// Ruby annotations (<rt>) are skipped: they would repeat the base text inline.
        var hidden = 0
        /// ASS overrides stay on until switched off or the cue ends.
        var assBold = false, assItalic = false, assUnderline = false, assStrikethrough = false
        var assColor: String?

        var run: SubtitleTextRun {
            SubtitleTextRun(text: "", bold: bold > 0 || assBold, italic: italic > 0 || assItalic,
                            underline: underline > 0 || assUnderline, strikethrough: strikethrough > 0 || assStrikethrough,
                            color: colors.last(where: { $0 != nil }) ?? assColor)
        }
    }

    static func runs(_ text: String) -> [SubtitleTextRun] {
        var runs: [SubtitleTextRun] = []
        var state = State()
        func append(_ string: String) {
            guard !string.isEmpty, state.hidden == 0 else { return }
            var run = state.run
            if let last = runs.last, last.sameStyle(as: run) {
                runs[runs.count - 1].text += string
            } else {
                run.text = string
                runs.append(run)
            }
        }
        let characters = Array(text)
        var index = 0
        var literal = ""
        func flush() { append(literal); literal = "" }
        while index < characters.count {
            let character = characters[index]
            if character == "<", let close = characters[index...].firstIndex(of: ">"),
               let tag = Tag(String(characters[(index + 1)..<close])) {
                flush()
                if apply(tag, to: &state) { append("\n") }
                index = close + 1
            } else if character == "{", index + 1 < characters.count, characters[index + 1] == "\\",
                      let close = characters[index...].firstIndex(of: "}") {
                flush()
                applyOverrides(String(characters[(index + 1)..<close]), to: &state)
                index = close + 1
            } else if character == "&", let end = characters[index...].prefix(12).firstIndex(of: ";"),
                      let decoded = entity(String(characters[(index + 1)..<end])) {
                literal += decoded
                index = end + 1
            } else {
                literal.append(character)
                index += 1
            }
        }
        flush()
        return trimmed(runs)
    }

    /// Cue text without markup, with its line breaks.
    static func plainText(_ text: String) -> String {
        runs(text).map(\.text).joined()
    }

    /// Lines trimmed of surrounding spaces, empty lines removed, as the plain-text parsers do.
    private static func trimmed(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun] {
        // Rebuilt character by character so each kept character keeps its run's style; cues are short.
        var styled: [(Character, Int)] = []
        for (number, run) in runs.enumerated() { styled += run.text.map { ($0, number) } }
        var kept: [(Character, Int)] = []
        var line: [(Character, Int)] = []
        func endLine() {
            var start = 0, end = line.count
            while start < end, line[start].0.isWhitespace { start += 1 }
            while end > start, line[end - 1].0.isWhitespace { end -= 1 }
            if start < end {
                if !kept.isEmpty { kept.append(("\n", line[start].1)) }
                kept += line[start..<end]
            }
            line = []
        }
        for item in styled { if item.0 == "\n" { endLine() } else { line.append(item) } }
        endLine()
        var result: [SubtitleTextRun] = []
        for (character, number) in kept {
            if let last = result.last, last.sameStyle(as: runs[number]) {
                result[result.count - 1].text.append(character)
            } else {
                var run = runs[number]
                run.text = String(character)
                result.append(run)
            }
        }
        return result
    }

    private struct Tag {
        let name: String
        let closing: Bool
        let classes: [String]
        let attributes: String

        init?(_ body: String) {
            // "a < b" is text: a tag name follows the bracket directly.
            guard let lead = body.first, lead.isLetter || lead.isNumber || lead == "/" else { return nil }
            var body = body.trimmingCharacters(in: .whitespaces)
            // WebVTT karaoke timestamps such as <00:01.500>.
            if lead.isNumber {
                guard body.contains(":"), body.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." }) else { return nil }
                name = "timestamp"; closing = false; classes = []; attributes = ""; return
            }
            closing = body.hasPrefix("/")
            if closing { body.removeFirst() }
            if body.hasSuffix("/") { body.removeLast() }
            guard let first = body.first, first.isLetter else { return nil }
            let head = body.prefix { !$0.isWhitespace }
            let parts = head.split(separator: ".").map { String($0).lowercased() }
            name = parts[0]
            classes = Array(parts.dropFirst())
            attributes = String(body.dropFirst(head.count))
        }
    }

    /// Returns true for a line break.
    private static func apply(_ tag: Tag, to state: inout State) -> Bool {
        let step = tag.closing ? -1 : 1
        func change(_ value: inout Int) { value = max(0, value + step) }
        switch tag.name {
        case "b", "strong": change(&state.bold)
        case "i", "em": change(&state.italic)
        case "u": change(&state.underline)
        case "s", "strike", "del": change(&state.strikethrough)
        case "br": return !tag.closing
        case "rt", "rp": change(&state.hidden)
        case "font", "c", "span":
            if tag.closing {
                if !state.colors.isEmpty { state.colors.removeLast() }
            } else {
                state.colors.append(fontColor(tag.attributes) ?? tag.classes.lazy.compactMap(namedColor).first)
            }
        default: break
        }
        return false
    }

    private static func fontColor(_ attributes: String) -> String? {
        guard let match = attributes.range(of: #"(?i)color\s*=\s*["']?\s*([#A-Za-z0-9]+)"#, options: .regularExpression) else { return nil }
        let value = attributes[match].split(separator: "=").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? ""
        return hexColor(value) ?? namedColor(value.lowercased())
    }

    /// "#RGB", "#RRGGBB" or "RRGGBB" as "#RRGGBB".
    static func hexColor(_ value: String) -> String? {
        var digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 else { return nil }
        return "#" + digits.uppercased()
    }

    private static func namedColor(_ name: String) -> String? {
        [
            "white": "#FFFFFF", "black": "#000000", "red": "#FF0000", "lime": "#00FF00", "green": "#00FF00",
            "blue": "#0000FF", "yellow": "#FFFF00", "cyan": "#00FFFF", "aqua": "#00FFFF", "magenta": "#FF00FF",
            "fuchsia": "#FF00FF", "orange": "#FFA500", "gray": "#808080", "grey": "#808080", "silver": "#C0C0C0",
        ][name]
    }

    /// The ASS overrides that change emphasis or color: \b \i \u \s with 0/1, \c / \1c with &HBBGGRR&, \r to reset.
    private static func applyOverrides(_ block: String, to state: inout State) {
        for item in block.split(separator: "\\").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            let lower = item.lowercased()
            if lower.hasPrefix("r") {
                state.assBold = false; state.assItalic = false; state.assUnderline = false; state.assStrikethrough = false
                state.assColor = nil
            } else if let flag = flag(lower, "b") {
                state.assBold = flag
            } else if let flag = flag(lower, "i") {
                state.assItalic = flag
            } else if let flag = flag(lower, "u") {
                state.assUnderline = flag
            } else if let flag = flag(lower, "s") {
                state.assStrikethrough = flag
            } else if lower.hasPrefix("c&h") || lower.hasPrefix("1c&h") {
                let digits = lower.drop { $0 != "h" }.dropFirst().prefix { $0.isHexDigit }
                guard let value = UInt32(digits, radix: 16) else { continue }
                state.assColor = String(format: "#%02X%02X%02X", value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF)
            }
        }
    }

    /// `\b1` / `\b0` (and the ASS weights `\b700`, `\b400`) as on/off; nil when `item` is another override.
    private static func flag(_ item: String, _ name: Character) -> Bool? {
        guard item.first == name, let value = Int(item.dropFirst()) else { return nil }
        return name == "b" && value >= 100 ? value >= 600 : value != 0
    }

    private static func entity(_ name: String) -> String? {
        switch name.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "lrm", "rlm": return ""
        default:
            let number = name.lowercased().hasPrefix("#x") ? UInt32(name.dropFirst(2), radix: 16)
                : name.hasPrefix("#") ? UInt32(name.dropFirst()) : nil
            return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}

/// How a track's cue text is laid out: as authored, forced onto one line, or at most two balanced lines.
nonisolated enum SubtitleLineMode: String, CaseIterable, Sendable {
    case original, single, double

    static let defaultValue = SubtitleLineMode.original

    /// Terminal width of a line, counting CJK characters double and markup not at all.
    private static func width(_ text: String) -> Int {
        let visible = text.contains("<") || text.contains("{") ? SubtitleMarkup.plainText(text) : text
        return visible.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
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
        // Markup stays whole inside its token, so a tag with attributes is never split at its spaces.
        var closing: Character?
        for character in text {
            let wide = character.unicodeScalars.first.map(isWide) ?? false
            if let end = closing {
                current.append(character)
                if character == end { closing = nil }
            } else if character == "<" || character == "{" {
                current.append(character)
                closing = character == "<" ? ">" : "}"
            } else if character == " " {
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
    /// Extensions of the subtitle files that can be opened.
    static let fileExtensions = ["srt", "vtt", "ass", "ssa"]

    /// Reads a local .srt/.vtt file, detecting common encodings (BOM, UTF-8, then legacy CJK code pages).
    static func document(at url: URL) throws -> SubtitleDocument {
        try Task.checkCancellation()
        let data: Data
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        }
        catch { throw SubtitleError.message("error.subtitle.unreadable") }
        guard data.count <= maximumBytes else { throw SubtitleError.message("error.subtitle.tooLarge") }
        let document = try SubtitleDocument(text: decode(data))
        try Task.checkCancellation()
        return document
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

/// Runs CPU/file work away from MainActor and propagates cancellation to the worker.
nonisolated enum SubtitleBackgroundWork {
    static func run<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}
