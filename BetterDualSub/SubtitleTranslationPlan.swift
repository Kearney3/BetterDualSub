import Foundation
import NaturalLanguage

/// Turns a track into the distinct texts a translator needs, and rebuilds a track with the same timing from the results.
nonisolated struct SubtitleTranslationPlan: Sendable {
    /// Distinct cue texts to translate: markup removed, lines joined, repeats ("Yeah.", "Thank you.") listed once.
    let sources: [String]
    private let items: [SubtitleItem]
    /// For each cue, the index of its text in `sources`; nil when it has no words to translate (music notes, numbers).
    private let sourceIndex: [Int?]

    init(document: SubtitleDocument) {
        var sources: [String] = []
        var lookup: [String: Int] = [:]
        sourceIndex = document.items.map { item in
            let text = Self.plainText(item.text)
            guard text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
            if let index = lookup[text] { return index }
            lookup[text] = sources.count
            sources.append(text)
            return sources.count - 1
        }
        self.sources = sources
        items = document.items
    }

    /// The cue text a translator should see: one line, without tags or entities. Lines of one sentence are often split
    /// across a cue, and translating them separately gives worse results.
    static func plainText(_ text: String) -> String {
        let markup = try! NSRegularExpression(pattern: #"<[^>]*>|\{\\[^}]*\}"#)
        var plain = markup.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        for (entity, value) in [("&lrm;", ""), ("&rlm;", ""), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            plain = plain.replacingOccurrences(of: entity, with: value)
        }
        return SubtitleLineMode.single.apply(to: plain).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Most likely language of the track, as a BCP 47 identifier such as "en" or "zh-Hans".
    var dominantLanguage: String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sources.prefix(300).joined(separator: "\n"))
        return recognizer.dominantLanguage.map(\.rawValue)
    }

    /// Rebuilds the track; `translations[i]` translates `sources[i]`. Cues without words keep their text,
    /// and cues whose translation came back empty are dropped.
    func document(translations: [String]) throws -> SubtitleDocument {
        guard translations.count == sources.count else { throw SubtitleError.message("error.translation.incomplete") }
        let translated = zip(items, sourceIndex).map { item, index in
            let text = index.map { translations[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? Self.plainText(item.text)
            return SubtitleItem(startMs: item.startMs, endMs: item.endMs, text: text)
        }
        return try SubtitleDocument(items: translated)
    }
}
