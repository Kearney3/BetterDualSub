import Foundation

/// One stretch of a bilingual track: the text of each language on screen from `startMs` to `endMs`.
nonisolated struct BilingualCue: Equatable, Sendable {
    let startMs: Int
    let endMs: Int
    let primary: String
    let secondary: String
}

nonisolated enum SubtitleOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case srt, ass
    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

/// How two tracks are written out once they are lined up.
nonisolated struct BilingualMergeOptions: Equatable, Sendable {
    enum Layout: String, CaseIterable, Identifiable, Sendable {
        /// One file with both languages in every cue.
        case combined
        /// Each track in its own file, Track 2 moved by its delay and snapped to Track 1.
        case separate
        var id: String { rawValue }
    }

    /// Cue starts and ends of Track 2 this close to a Track 1 one are moved onto it (`SubtitleDocument.snapped`).
    var tolerance = 500
    /// Added to every Track 2 time before lining up.
    var secondaryOffsetMs = 0
    var secondaryOnTop = false
    var format = SubtitleOutputFormat.srt
    var layout = Layout.combined
}

/// A file to write: what it holds and its contents.
nonisolated struct SubtitleOutputFile: Equatable, Sendable {
    enum Role: Sendable { case bilingual, primary, secondary, translation }
    let role: Role
    let contents: String
}

nonisolated extension SubtitleDocument {
    /// Both tracks cleaned up for output, Track 2 moved by `secondaryOffsetMs` and snapped to Track 1, cut into
    /// stretches where the text of both stays the same.
    static func bilingualCues(primary: SubtitleDocument, secondary: SubtitleDocument, secondaryOffsetMs: Int = 0,
                              tolerance: Int) throws -> [BilingualCue] {
        let (first, second) = try lined(primary: primary, secondary: secondary, secondaryOffsetMs: secondaryOffsetMs, tolerance: tolerance)
        let bounds = Set((first.items + second.items).flatMap { [$0.startMs, $0.endMs] }).sorted()
        var cues: [BilingualCue] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            let top = first.text(at: start), bottom = second.text(at: start)
            guard !top.isEmpty || !bottom.isEmpty else { continue }
            if let last = cues.last, last.endMs == start, last.primary == top, last.secondary == bottom {
                cues[cues.count - 1] = BilingualCue(startMs: last.startMs, endMs: end, primary: top, secondary: bottom)
            } else {
                cues.append(BilingualCue(startMs: start, endMs: end, primary: top, secondary: bottom))
            }
        }
        return withoutFlashes(cues)
    }

    /// Stretches too short to read, as a few-millisecond gap between two lines of one track leaves under a line of the
    /// other, given to the cue they touch, so players do not flicker.
    private static func withoutFlashes(_ cues: [BilingualCue], shortest: Int = 100) -> [BilingualCue] {
        var kept: [BilingualCue] = []
        var pending: BilingualCue?
        for cue in cues {
            var cue = cue
            if let short = pending {
                pending = nil
                if short.endMs == cue.startMs {
                    cue = BilingualCue(startMs: short.startMs, endMs: cue.endMs, primary: cue.primary, secondary: cue.secondary)
                } else {
                    kept.append(short)
                }
            }
            if cue.endMs - cue.startMs < shortest {
                if let last = kept.last, last.endMs == cue.startMs {
                    kept[kept.count - 1] = BilingualCue(startMs: last.startMs, endMs: cue.endMs, primary: last.primary, secondary: last.secondary)
                } else {
                    pending = cue
                }
                continue
            }
            kept.append(cue)
        }
        if let pending { kept.append(pending) }
        return kept
    }

    /// Track 1 cleaned up, and Track 2 cleaned up, moved by its delay and snapped to Track 1.
    private static func lined(primary: SubtitleDocument, secondary: SubtitleDocument, secondaryOffsetMs: Int,
                              tolerance: Int) throws -> (SubtitleDocument, SubtitleDocument) {
        let first = try SubtitleDocument(items: primary.items.compactMap { cleaned($0) }, allowEmpty: true)
        let second = try SubtitleDocument(items: secondary.items.compactMap { cleaned($0) }.compactMap { item -> SubtitleItem? in
            let start = max(0, item.startMs + secondaryOffsetMs), end = max(0, item.endMs + secondaryOffsetMs)
            return end > start ? SubtitleItem(startMs: start, endMs: end, text: item.text) : nil
        }, allowEmpty: true).snapped(to: first, tolerance: tolerance)
        return (first, second)
    }

    /// The files `options` asks for: one bilingual file, or both tracks lined up in files of their own.
    static func merged(primary: SubtitleDocument, secondary: SubtitleDocument,
                       options: BilingualMergeOptions) throws -> [SubtitleOutputFile] {
        switch options.layout {
        case .combined:
            let cues = try bilingualCues(primary: primary, secondary: secondary, secondaryOffsetMs: options.secondaryOffsetMs,
                                         tolerance: options.tolerance)
            guard !cues.isEmpty else { throw SubtitleError.message("error.subtitle.empty") }
            let contents = switch options.format {
            case .srt:
                try bilingual(primary: primary, secondary: secondary, secondaryOffsetMs: options.secondaryOffsetMs,
                              tolerance: options.tolerance, secondaryOnTop: options.secondaryOnTop).srt
            case .ass:
                ass(cues: cues, secondaryOnTop: options.secondaryOnTop)
            }
            return [SubtitleOutputFile(role: .bilingual, contents: contents)]
        case .separate:
            let (first, second) = try lined(primary: primary, secondary: secondary, secondaryOffsetMs: options.secondaryOffsetMs,
                                            tolerance: options.tolerance)
            guard !first.items.isEmpty, !second.items.isEmpty else { throw SubtitleError.message("error.subtitle.empty") }
            return [SubtitleOutputFile(role: .primary, contents: first.contents(options.format)),
                    SubtitleOutputFile(role: .secondary, contents: second.contents(options.format))]
        }
    }

    /// This track as a file of `format`.
    func contents(_ format: SubtitleOutputFormat) -> String {
        switch format {
        case .srt: srt
        case .ass:
            Self.ass(cues: items.compactMap(Self.cleaned).map {
                BilingualCue(startMs: $0.startMs, endMs: $0.endMs, primary: $0.text, secondary: "")
            }, secondaryOnTop: false)
        }
    }

    /// An Advanced SubStation Alpha script: Track 1 in the `Primary` style and Track 2 in the smaller `Secondary` style,
    /// both in one event per stretch so the two languages always stack the same way.
    static func ass(cues: [BilingualCue], secondaryOnTop: Bool) -> String {
        let format = "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
            + "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
        func style(_ name: String, size: Int) -> String {
            "Style: \(name),Arial,\(size),&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2.5,0.5,2,60,60,48,1"
        }
        var lines = ["[Script Info]", "ScriptType: v4.00+", "PlayResX: 1920", "PlayResY: 1080", "WrapStyle: 0",
                     "ScaledBorderAndShadow: yes", "", "[V4+ Styles]", format, style("Primary", size: 64), style("Secondary", size: 48), "",
                     "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
        for cue in cues {
            let parts = [("Primary", cue.primary), ("Secondary", cue.secondary)].filter { !$0.1.isEmpty }
            let ordered = secondaryOnTop ? parts.reversed() : parts
            guard let first = ordered.first else { continue }
            // `\r<Style>` switches style inside the event for the second language.
            let text = ordered.enumerated().map { index, part in
                (index == 0 ? "" : "\\N{\\r\(part.0)}") + assText(part.1)
            }.joined()
            lines.append("Dialogue: 0,\(assTime(cue.startMs)),\(assTime(cue.endMs)),\(first.0),,0,0,0,,\(text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Cue text in ASS markup: line breaks as `\N`, b/i/u tags as overrides. ASS has no escape for braces, which would
    /// start an override block, so they become parentheses.
    static func assText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        for tag in ["b", "i", "u"] {
            result = result.replacingOccurrences(of: "<\(tag)>", with: "{\\\(tag)1}", options: .caseInsensitive)
                .replacingOccurrences(of: "</\(tag)>", with: "{\\\(tag)0}", options: .caseInsensitive)
        }
        return result.components(separatedBy: "\n").joined(separator: "\\N")
    }

    /// `H:MM:SS.cc`, in centiseconds as ASS times are.
    static func assTime(_ milliseconds: Int) -> String {
        let value = max(0, milliseconds) / 10
        return String(format: "%d:%02d:%02d.%02d", value / 360_000, value / 6000 % 60, value / 100 % 60, value % 100)
    }

    /// How much later (positive) or earlier this track must be shown to line up with `reference`, when the two are
    /// one video's subtitles shifted by a constant amount, such as a recap or logo at the start of only one of them;
    /// nil when too few lines match to tell. Every pair of cue starts within 5 minutes votes for its difference, the
    /// most voted 100 ms bucket wins, and the median of the differences near it is the answer, rounded to 10 ms.
    func estimatedOffset(to reference: SubtitleDocument, window: Int = 300_000, minimumMatches: Int = 10) -> Int? {
        let starts = reference.items.map(\.startMs).sorted()
        guard !starts.isEmpty else { return nil }
        func firstIndex(atOrAfter value: Int) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] < value { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let bucket = 100
        var votes: [Int: Int] = [:]
        for item in items {
            var index = firstIndex(atOrAfter: item.startMs - window)
            while index < starts.count, starts[index] <= item.startMs + window {
                votes[Int((Double(starts[index] - item.startMs) / Double(bucket)).rounded()), default: 0] += 1
                index += 1
            }
        }
        // A difference near a bucket edge splits its votes, so neighbouring buckets count too.
        guard let best = votes.keys.max(by: { a, b in
            let score = { (key: Int) in (votes[key - 1] ?? 0) + 2 * (votes[key] ?? 0) + (votes[key + 1] ?? 0) }
            return score(a) != score(b) ? score(a) < score(b) : abs(a) > abs(b)
        }) else { return nil }
        let center = best * bucket
        let near = items.compactMap { item -> Int? in
            let index = firstIndex(atOrAfter: item.startMs + center - bucket * 3)
            guard index < starts.count, abs(starts[index] - item.startMs - center) <= bucket * 3 else { return nil }
            return starts[index] - item.startMs
        }.sorted()
        // Dense cues land near some reference cue by chance alone; a real offset lines up clearly more of them.
        let span = max(1, (starts.last ?? 0) - (starts.first ?? 0))
        let chance = Double(items.count) * min(1, Double(starts.count * (bucket * 6 + 1)) / Double(span))
        guard Double(near.count) >= max(Double(minimumMatches), min(chance * 2, (chance + Double(items.count)) / 2)) else { return nil }
        return Int((Double(near[near.count / 2]) / 10).rounded()) * 10
    }
}

/// Season and episode read from a file name, to put the files of a season in order and pair two languages.
nonisolated struct EpisodeKey: Hashable, Comparable, Sendable {
    var season: Int?
    var episode: Int

    /// "S01E02" / "E02" style, for file names and lists.
    var label: String {
        season.map { String(format: "S%02dE%02d", $0, episode) } ?? String(format: "E%02d", episode)
    }

    static func < (a: EpisodeKey, b: EpisodeKey) -> Bool {
        (a.season ?? 0, a.episode) < (b.season ?? 0, b.episode)
    }

    /// Whether two files are the same episode; a name without a season matches any season.
    func matches(_ other: EpisodeKey) -> Bool {
        episode == other.episode && (season == nil || other.season == nil || season == other.season)
    }

    private static let patterns: [(String, season: Int?, episode: Int)] = [
        (#"(?i)S(\d{1,2})[ ._-]?E(\d{1,3})"#, 1, 2),
        (#"(?i)(?<![\dx])(\d{1,2})x(\d{1,3})(?!\d)"#, 1, 2),
        (#"第\s*(\d{1,3})\s*[集话話]"#, nil, 1),
        (#"(?i)(?<![a-z])(?:episode|ep|e)[ ._-]?(\d{1,3})(?!\d)"#, nil, 1),
    ]

    /// The episode in `filename`, from the first pattern that matches; otherwise the last number of up to three
    /// digits that is not a resolution such as 720p or a codec such as x264.
    static func parse(_ filename: String) -> EpisodeKey? {
        let name = (filename as NSString).deletingPathExtension
        let range = NSRange(name.startIndex..., in: name)
        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            Range(match.range(at: group), in: name).flatMap { Int(name[$0]) }
        }
        for (pattern, season, episode) in patterns {
            guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: name, range: range),
                  let value = number(match, episode) else { continue }
            return EpisodeKey(season: season.flatMap { number(match, $0) }, episode: value)
        }
        // Codec names (x264, H.265) and audio channels (7.1) are not episodes either.
        let fallback = try? NSRegularExpression(pattern: #"(?<![\dxXhH])(?<![hH]\.)(?<!\d\.)(\d{1,3})(?![\dpPkK])(?!\.\d)"#)
        guard let match = fallback?.matches(in: name, range: range).last, let value = number(match, 1) else { return nil }
        return EpisodeKey(episode: value)
    }

    /// Pairs each Track 1 file with the Track 2 file of the same episode, in episode order. Files with no episode in
    /// their name, or no partner, are returned as unmatched.
    static func pair(primary: [URL], secondary: [URL]) -> (pairs: [(primary: URL, secondary: URL, key: EpisodeKey)],
                                                         unmatchedPrimary: [URL], unmatchedSecondary: [URL]) {
        var remaining = secondary.compactMap { url in parse(url.lastPathComponent).map { (url, $0) } }
        var pairs: [(primary: URL, secondary: URL, key: EpisodeKey)] = []
        var unmatched: [URL] = []
        for url in primary {
            guard let key = parse(url.lastPathComponent),
                  let index = remaining.firstIndex(where: { $0.1 == key }) ?? remaining.firstIndex(where: { $0.1.matches(key) }) else {
                unmatched.append(url)
                continue
            }
            pairs.append((url, remaining[index].0, key))
            remaining.remove(at: index)
        }
        let paired = Set(pairs.map(\.secondary))
        return (pairs.sorted { $0.key < $1.key }, unmatched, secondary.filter { !paired.contains($0) })
    }
}

/// Subtitle files among dropped or chosen files and folders.
nonisolated enum SubtitleFileScanner {
    /// The subtitle files in `urls`, folders expanded (their subfolders too with `recursive`), in episode order.
    static func files(in urls: [URL], recursive: Bool = false) -> [URL] {
        var found: [URL] = []
        let manager = FileManager.default
        for url in urls {
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue {
                if isSubtitle(url) { found.append(url) }
                continue
            }
            let options: FileManager.DirectoryEnumerationOptions = recursive
                ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            let items = manager.enumerator(at: url, includingPropertiesForKeys: nil, options: options)?.compactMap { $0 as? URL } ?? []
            found += items.filter(isSubtitle)
        }
        var seen = Set<URL>()
        return sorted(found.map(\.standardizedFileURL).filter { seen.insert($0).inserted })
    }

    static func isSubtitle(_ url: URL) -> Bool {
        SubtitleFileReader.fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Episode order where names have episodes, then the Finder's name order.
    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { a, b in
            let ka = EpisodeKey.parse(a.lastPathComponent), kb = EpisodeKey.parse(b.lastPathComponent)
            if let ka, let kb, ka != kb { return ka < kb }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }
}

/// Names of the files a merge or batch writes, from a pattern such as `{name}.{lang}`.
nonisolated enum OutputNaming {
    enum ExistingFile: String, CaseIterable, Identifiable, Sendable {
        case skip, overwrite, rename
        var id: String { rawValue }
    }

    static let tokens = ["{name}", "{lang}", "{episode}"]

    /// The file name for `source`: `{name}` is its name without extension, `{lang}` the language code, `{episode}`
    /// its episode ("S01E02"). With `{lang}` in the pattern, a tag naming `sourceLanguage` at the end of the name is
    /// left out, so "Show.S01E02.en" becomes "Show.S01E02.zh-Hans" rather than "Show.S01E02.en.zh-Hans". Characters a
    /// file name cannot hold are removed.
    static func fileName(pattern: String, source: URL, language: String = "", sourceLanguage: Locale.Language? = nil,
                         format: SubtitleOutputFormat) -> String {
        var stem = source.deletingPathExtension().lastPathComponent
        var name = pattern.trimmingCharacters(in: .whitespaces).isEmpty ? "{name}" : pattern
        if name.contains("{lang}"), let sourceLanguage { stem = removingLanguageTag(stem, sourceLanguage) }
        name = name.replacingOccurrences(of: "{name}", with: stem)
            .replacingOccurrences(of: "{lang}", with: language)
            .replacingOccurrences(of: "{episode}", with: EpisodeKey.parse(source.lastPathComponent)?.label ?? "")
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/:\\".unicodeScalars.contains($0) })
        // Empty tokens leave doubled or trailing separators behind ("Show..srt").
        while name.contains("..") { name = name.replacingOccurrences(of: "..", with: ".") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". -_").union(.whitespaces))
        return (name.isEmpty ? stem : name) + "." + format.fileExtension
    }

    /// Tags that name a language in file names but are not language codes.
    private static let languageAliases = ["chs": "zh", "cht": "zh", "chi": "zh", "cmn": "zh", "sc": "zh", "tc": "zh",
                                          "english": "en", "chinese": "zh", "japanese": "ja", "korean": "ko"]

    /// `stem` without its last part when that part names `language` ("en", "eng", "zh-Hans", "chs").
    static func removingLanguageTag(_ stem: String, _ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier,
              let cut = stem.lastIndex(where: { $0 == "." || $0 == " " }), cut > stem.startIndex else { return stem }
        let tag = stem[stem.index(after: cut)...].lowercased()
        let named = languageAliases[tag] ?? Locale.Language(identifier: tag).languageCode.flatMap { $0.isISOLanguage ? $0.identifier : nil }
        return named == code ? String(stem[..<cut]) : stem
    }

    /// Where to write `fileName` in `folder`, or nil to skip it. An existing file is kept, replaced or given a free
    /// name ("Name 2.srt") as `existing` says; a file being read (`protected`) is never replaced.
    static func destination(fileName: String, in folder: URL, existing: ExistingFile, protected: Set<URL> = [],
                            fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        let url = folder.appendingPathComponent(fileName)
        let isProtected = protected.contains(url.standardizedFileURL)
        guard fileExists(url) || isProtected else { return url }
        switch existing {
        case .skip: return nil
        case .overwrite where !isProtected: return url
        case .overwrite, .rename:
            let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            for number in 2... {
                let candidate = folder.appendingPathComponent("\(stem) \(number).\(ext)")
                if !fileExists(candidate), !protected.contains(candidate.standardizedFileURL) { return candidate }
            }
            return nil
        }
    }
}
