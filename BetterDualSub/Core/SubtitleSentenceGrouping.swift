import Foundation

/// Finds cues that share one sentence ("I don't think" / "we should go."), so the sentence is translated whole and
/// its translation shared out over the same cues again.
nonisolated enum SubtitleSentenceGrouping {
    static let maximumCues = 4
    static let maximumLength = 250
    static let maximumGapMs = 1000

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！", "‼", "⁇", "⁈", "⁉", "♪", "♫"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "」", "』", ")", "）", "]", "】", "》", " "]
    private static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "st.", "jr.", "sr.", "vs.", "prof.", "mt."]

    /// Groups consecutive cues; `texts[i]` is the plain text of `items[i]`, nil when it has no words, which ends a group.
    /// A track that rarely ends a cue with punctuation gets no groups: there a missing full stop says nothing.
    static func groups(items: [SubtitleItem], texts: [String?]) -> [[Int]] {
        let words = texts.compactMap { $0 }
        let grouping = !words.isEmpty && Double(words.filter(endsSentence).count) >= Double(words.count) * 0.3
        var groups: [[Int]] = []
        var current: [Int] = []
        var length = 0
        for index in items.indices {
            guard let text = texts[index] else {
                if !current.isEmpty { groups.append(current) }
                current = []
                continue
            }
            if grouping, let last = current.last, let previous = texts[last], current.count < maximumCues,
               length + text.count <= maximumLength, continues(previous, items[last], into: text, items[index]) {
                current.append(index)
                length += text.count
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [index]
                length = text.count
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Whether `next` carries on the sentence of `text`: close in time, not overlapping (another speaker), not a new
    /// line of dialogue, and `text` has not ended its sentence.
    static func continues(_ text: String, _ cue: SubtitleItem, into next: String, _ nextCue: SubtitleItem) -> Bool {
        let gap = nextCue.startMs - cue.endMs
        guard gap >= -50, gap <= maximumGapMs, !startsNewLine(next) else { return false }
        let trimmed = String(text.reversed().drop(while: closers.contains).reversed())
        if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") {
            // "I was thinking..." / "...maybe not." continues; "Wait..." / "Who's there?" does not.
            let rest = next.drop { $0 == "." || $0 == "…" || $0 == " " }
            return next.hasPrefix("...") || next.hasPrefix("…") || rest.first?.isLowercase == true
        }
        return !endsSentence(text)
    }

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = String(text.reversed().drop(while: closers.contains).reversed())
        guard let last = trimmed.last, sentenceEnds.contains(last) else { return false }
        let word = trimmed.split(separator: " ").last.map { $0.lowercased() } ?? ""
        return !abbreviations.contains(word)
    }

    /// Dialogue dashes and speaker or sound labels ("[Man]", "(laughs)") start a line of their own.
    private static func startsNewLine(_ text: String) -> Bool {
        guard let first = text.first else { return true }
        return ["-", "–", "[", "(", "（", "【"].contains(first)
    }
}
