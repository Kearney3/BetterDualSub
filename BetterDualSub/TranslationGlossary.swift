import Foundation

/// How one name or term is always translated.
nonisolated struct GlossaryEntry: Codable, Hashable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, CaseIterable, Sendable {
        case person, place, organization, term
    }

    var id = UUID()
    var source: String
    var target: String
    var kind: Kind = .term
    var note = ""
    /// Found by the translator rather than written by the user; the user's own entries always win.
    var automatic = false

    init(source: String, target: String, kind: Kind = .term, note: String = "", automatic: Bool = false) {
        self.source = source
        self.target = target
        self.kind = kind
        self.note = note
        self.automatic = automatic
    }
}

/// The names and terms of one show in one target language, so every episode translates them the same way.
nonisolated struct TranslationGlossary: Codable, Equatable, Sendable {
    var name: String
    /// Maximal identifier of the language the targets are in ("zh-Hans-CN").
    var targetLanguage: String
    var entries: [GlossaryEntry] = []

    /// The show a title belongs to, so episodes share one glossary: "Show.Name.S01E02.1080p" → "Show Name".
    static func seriesName(from title: String) -> String {
        var name = title
        let patterns = [#"(?i)[\s._\-–—:·]*\bS\d{1,2}\s*[._\-]?\s*E\d{1,4}\b.*$"#, #"(?i)[\s._\-–—:·]*\b\d{1,2}x\d{2,3}\b.*$"#,
                        #"(?i)[\s._\-–—:·]*\b(Season|Series|Episode|Ep)\s*\d+.*$"#, #"[\s._\-–—:·]*第\s*[\d一二三四五六七八九十百]+\s*[季集话話部].*$"#,
                        #"(?i)[\s._\-]*\b(2160p|1080p|720p|480p|WEB(-?DL|Rip)?|BluRay|HDTV|x26[45]|HEVC)\b.*$"#]
        for pattern in patterns {
            name = name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if !name.contains(" ") { name = name.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return name.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }

    /// Entries whose source occurs in `text`, longest first, each occurrence counted once ("New York City" before
    /// "New York"). Latin terms match whole words, ignoring case; CJK terms match anywhere.
    func matches(in text: String) -> [GlossaryEntry] {
        var taken: [Range<String.Index>] = []
        var found: [GlossaryEntry] = []
        for entry in entries.sorted(by: { $0.source.count > $1.source.count }) where !entry.source.isEmpty {
            let ranges = Self.ranges(of: entry.source, in: text).filter { range in !taken.contains { $0.overlaps(range) } }
            guard !ranges.isEmpty else { continue }
            taken += ranges
            found.append(entry)
        }
        return found
    }

    /// Writes each matched term's translation into `text`, for translators that cannot be told about a glossary:
    /// they tend to keep words of another script as they are.
    func substitute(in text: String) -> String {
        var result = text
        for entry in matches(in: text) where !entry.target.isEmpty {
            for range in Self.ranges(of: entry.source, in: result).reversed() {
                result.replaceSubrange(range, with: entry.target)
            }
        }
        return result
    }

    /// Entries whose source occurs in `source` but whose translation is missing from `translation`.
    func violations(source: String, translation: String) -> [GlossaryEntry] {
        matches(in: source).filter { !$0.target.isEmpty && translation.range(of: $0.target, options: [.caseInsensitive]) == nil }
    }

    /// The glossary without the entries of `kinds` that the translator found, for names the user wants left as they
    /// are; the user's own entries stay.
    func excludingAutomatic(_ kinds: Set<GlossaryEntry.Kind>) -> TranslationGlossary {
        var glossary = self
        if !kinds.isEmpty { glossary.entries.removeAll { $0.automatic && kinds.contains($0.kind) } }
        return glossary
    }

    /// Adds entries for terms not yet listed; returns how many were added. Existing entries, which the user may have
    /// corrected, are never replaced.
    @discardableResult
    mutating func merge(_ found: [GlossaryEntry]) -> Int {
        var known = Set(entries.map { Self.key($0.source) })
        var added = 0
        for entry in found {
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = entry.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !target.isEmpty, known.insert(Self.key(source)).inserted else { continue }
            entries.append(GlossaryEntry(source: source, target: target, kind: entry.kind, note: entry.note, automatic: true))
            added += 1
        }
        return added
    }

    /// Tab-separated `source  target  kind  note` lines, with `#` comments; also reads `source → target` and
    /// `source = target` lines, as other glossary tools write them.
    static func entries(fromTSV text: String) -> [GlossaryEntry] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            var fields = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count < 2, let separator = ["→", "=>", "->", "="].first(where: line.contains) {
                fields = line.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
            }
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return GlossaryEntry(source: fields[0], target: fields[1],
                                 kind: fields.count > 2 ? GlossaryEntry.Kind(rawValue: fields[2].lowercased()) ?? .term : .term,
                                 note: fields.count > 3 ? fields[3] : "")
        }
    }

    var tsv: String {
        let clean = { (text: String) in text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        return (["# source\ttarget\tkind\tnote"] + entries.map {
            [clean($0.source), clean($0.target), $0.kind.rawValue, clean($0.note)].joined(separator: "\t")
        }).joined(separator: "\n") + "\n"
    }

    private static func key(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: term, options: [.caseInsensitive], range: start..<text.endIndex) {
            if isWholeWord(range, in: text) { ranges.append(range) }
            start = range.upperBound
        }
        return ranges
    }

    /// Latin terms must not run into letters on either side ("Ann" is not in "Anna"); CJK terms have no spaces to go by.
    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        func joins(_ character: Character?, _ edge: Character) -> Bool {
            guard let character, let scalar = character.unicodeScalars.first, let edgeScalar = edge.unicodeScalars.first,
                  !SubtitleLineMode.isWide(edgeScalar) else { return false }
            return (character.isLetter || character.isNumber) && !SubtitleLineMode.isWide(scalar)
        }
        let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        return !joins(before, text[range.lowerBound]) && !joins(after, text[text.index(before: range.upperBound)])
    }
}

/// Glossaries in `~/Library/Application Support/BetterDualSub/Glossaries`, one JSON file per show and target language.
actor GlossaryStore {
    static let shared = GlossaryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BetterDualSub/Glossaries", isDirectory: true))

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The saved glossary, or an empty one with that name.
    func load(name: String, targetLanguage: String) throws -> TranslationGlossary {
        let url = fileURL(name: name, targetLanguage: targetLanguage)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TranslationGlossary(name: name, targetLanguage: targetLanguage)
        }
        return try JSONDecoder().decode(TranslationGlossary.self, from: Data(contentsOf: url))
    }

    func save(_ glossary: TranslationGlossary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(glossary).write(to: fileURL(name: glossary.name, targetLanguage: glossary.targetLanguage), options: .atomic)
    }

    /// Names of the saved glossaries for a target language, sorted.
    func names(targetLanguage: String) -> [String] {
        let suffix = ".\(Self.fileComponent(targetLanguage)).json"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> String? in
            guard url.lastPathComponent.hasSuffix(suffix),
                  let data = try? Data(contentsOf: url),
                  let glossary = try? JSONDecoder().decode(TranslationGlossary.self, from: data) else { return nil }
            return glossary.name
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func fileURL(name: String, targetLanguage: String) -> URL {
        directory.appendingPathComponent("\(Self.fileComponent(name)).\(Self.fileComponent(targetLanguage)).json")
    }

    private static func fileComponent(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    }
}
