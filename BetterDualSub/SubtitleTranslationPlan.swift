import Foundation
import NaturalLanguage

/// One sentence to translate: the plain text of each cue it is spoken over, in order.
nonisolated struct SubtitleTranslationUnit: Hashable, Sendable {
    let segments: [String]

    /// The whole sentence, as a translator should see it.
    var text: String { segments.dropFirst().reduce(segments.first ?? "", SubtitleLineMode.join) }
}

/// Turns a track into the distinct sentences a translator needs, and rebuilds a track with the same timing from the results.
nonisolated struct SubtitleTranslationPlan: Sendable {
    /// Distinct sentences to translate: markup removed, lines joined, a sentence split over several cues joined
    /// (see `SubtitleSentenceGrouping`), repeats ("Yeah.", "Thank you.") listed once.
    let units: [SubtitleTranslationUnit]
    private let items: [SubtitleItem]
    /// The cues of each occurrence of a sentence, and the index of that sentence in `units`. Cues in no group have no
    /// words to translate (music notes, numbers).
    private let groups: [(cues: [Int], unit: Int)]

    var sources: [String] { units.map(\.text) }

    init(document: SubtitleDocument) {
        items = document.items
        let texts: [String?] = items.map { item in
            let text = Self.plainText(item.text)
            return text.unicodeScalars.contains(where: CharacterSet.letters.contains) ? text : nil
        }
        var units: [SubtitleTranslationUnit] = []
        var lookup: [SubtitleTranslationUnit: Int] = [:]
        groups = SubtitleSentenceGrouping.groups(items: items, texts: texts).map { cues in
            let unit = SubtitleTranslationUnit(segments: cues.compactMap { texts[$0] })
            if let index = lookup[unit] { return (cues, index) }
            lookup[unit] = units.count
            units.append(unit)
            return (cues, units.count - 1)
        }
        self.units = units
    }

    /// The cue text a translator should see: one line, without tags or entities. Lines of one sentence are often split
    /// across a cue, and translating them separately gives worse results.
    static func plainText(_ text: String) -> String {
        SubtitleLineMode.single.apply(to: SubtitleMarkup.plainText(text)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Most likely language of the track, as a BCP 47 identifier such as "en" or "zh-Hans".
    var dominantLanguage: String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sources.prefix(300).joined(separator: "\n"))
        return recognizer.dominantLanguage.map(\.rawValue)
    }

    func preview(maximumCues: Int = 8) throws -> SubtitleTranslationPlan {
        SubtitleTranslationPlan(document: try SubtitleDocument(items: Array(items.prefix(max(1, maximumCues)))))
    }

    /// Rebuilds the track; `translations[u]` holds one line for each segment of `units[u]`. A line left empty gives
    /// its time to the line before it in the same sentence (or after it, for the first), a sentence that came back
    /// empty is dropped, and cues without words keep their text.
    func document(translations: [[String]]) throws -> SubtitleDocument {
        guard translations.count == units.count,
              zip(translations, units).allSatisfy({ $0.count == $1.segments.count }) else {
            throw SubtitleError.message("error.translation.incomplete")
        }
        var translated: [SubtitleItem] = []
        var grouped = Set<Int>()
        for (cues, unit) in groups {
            grouped.formUnion(cues)
            var spans: [(start: Int, end: Int, text: String)] = []
            var leadingStart: Int?
            for (cue, line) in zip(cues, translations[unit]) {
                let item = items[cue], text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    spans.append((leadingStart ?? item.startMs, item.endMs, text))
                    leadingStart = nil
                } else if spans.isEmpty {
                    leadingStart = leadingStart ?? item.startMs
                } else {
                    spans[spans.count - 1].end = item.endMs
                }
            }
            translated += spans.map { SubtitleItem(startMs: $0.start, endMs: $0.end, text: $0.text) }
        }
        for (index, item) in items.enumerated() where !grouped.contains(index) {
            translated.append(SubtitleItem(startMs: item.startMs, endMs: item.endMs, text: Self.plainText(item.text)))
        }
        return try SubtitleDocument(items: translated)
    }
}
