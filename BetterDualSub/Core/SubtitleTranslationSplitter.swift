import Foundation
import NaturalLanguage

/// Shares a translated sentence out over the cues its source was spoken in, and breaks up translated lines too long
/// for one cue.
nonisolated enum SubtitleTranslationSplitter {
    private static let strong: Set<Character> = [".", "?", "!", "…", ";", "。", "？", "！", "；"]
    private static let weak: Set<Character> = [",", ":", "—", "，", "、", "："]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "」", "』", ")", "）", "]", "】", "》"]
    private static let openers: Set<Character> = ["\"", "“", "‘", "「", "『", "(", "（", "[", "【", "《"]

    /// Splits `translation` into `weights.count` lines whose lengths follow `weights` (usually the widths of the source
    /// lines), cutting after punctuation where one is close, otherwise between words, never inside one. Lines it has
    /// no words left for come back empty.
    static func split(_ translation: String, weights: [Int]) -> [String] {
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard weights.count > 1 else { return [text] }
        let characters = Array(text)
        var widths = [0]
        for character in characters { widths.append(widths[widths.count - 1] + width(character)) }
        let total = Double(max(1, widths[widths.count - 1]))
        let weightTotal = Double(max(1, weights.reduce(0) { $0 + max(0, $1) }))
        let cuts = candidates(text, characters)
        var chosen: [Int] = []
        var running = 0, next = 0
        for line in 1..<weights.count {
            running += max(0, weights[line - 1])
            let ideal = total * Double(running) / weightTotal
            // Leave enough later cuts for the lines still to come.
            let still = weights.count - 1 - line
            guard next < cuts.count - still else { break }
            var best = next, bestCost = Double.infinity
            for index in next..<(cuts.count - still) {
                let cost = abs(Double(widths[cuts[index].offset]) - ideal) / total + cuts[index].penalty
                if cost < bestCost { bestCost = cost; best = index }
            }
            chosen.append(cuts[best].offset)
            next = best + 1
        }
        var lines: [String] = []
        var start = 0
        for offset in chosen + [characters.count] {
            lines.append(String(characters[start..<offset]).trimmingCharacters(in: .whitespaces))
            start = offset
        }
        return lines + Array(repeating: "", count: weights.count - lines.count)
    }

    /// Breaks cues wider than two lines into parts shown one after another within the cue's time, each at least
    /// `minimumMs` long. Time is shared by length, so the reading speed stays the same.
    static func subdivide(_ document: SubtitleDocument, minimumMs: Int = 1200) throws -> SubtitleDocument {
        var items: [SubtitleItem] = []
        for item in document.items {
            let text = item.text.replacingOccurrences(of: "\n", with: " ")
            let width = SubtitleLineMode.width(text)
            let wide = text.unicodeScalars.filter(SubtitleLineMode.isWide).count * 2 > text.count
            let limit = wide ? 64 : 84
            let duration = item.endMs - item.startMs
            let parts = min(duration / max(1, minimumMs), Int((Double(width) / Double(limit)).rounded(.up)))
            guard width > limit, parts >= 2 else { items.append(item); continue }
            let lines = split(text, weights: Array(repeating: 1, count: parts)).filter { !$0.isEmpty }
            guard lines.count >= 2 else { items.append(item); continue }
            let lineWidths = lines.map(SubtitleLineMode.width)
            let totalWidth = max(1, lineWidths.reduce(0, +))
            let spare = duration - minimumMs * lines.count
            var start = item.startMs
            for (index, line) in lines.enumerated() {
                let end = index == lines.count - 1 ? item.endMs : start + minimumMs + spare * lineWidths[index] / totalWidth
                items.append(SubtitleItem(startMs: start, endMs: end, text: line))
                start = end
            }
        }
        return try SubtitleDocument(items: items)
    }

    /// Chinese and Japanese subtitle style: no full stop or comma, a space where a pause falls inside a line. Question
    /// and exclamation marks, ellipses and quotes stay; so does the Chinese enumeration comma "、".
    static func subtitlePunctuation(_ text: String, japanese: Bool) -> String {
        let pauses: Set<Character> = japanese ? ["，", "。", "、", "．"] : ["，", "。", "．"]
        return text.components(separatedBy: "\n").map { line in
            var result = String(line.map { pauses.contains($0) ? " " : $0 })
            result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            // A pause that ran into a quote or bracket leaves no space beside it: 「好。」 → 「好」.
            result = result.replacingOccurrences(of: #" +(?=[”’」』）)》】？！?!…])"#, with: "", options: .regularExpression)
            result = result.replacingOccurrences(of: #"(?<=[“‘「『（(《【]) +"#, with: "", options: .regularExpression)
            return result.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// Where a line may end, as a character offset, with a penalty: none after a full stop, a little after a comma,
    /// more between two words.
    private static func candidates(_ text: String, _ characters: [Character]) -> [(offset: Int, penalty: Double)] {
        guard characters.count > 1 else { return [] }
        var boundaries = Set<Int>()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            boundaries.insert(text.distance(from: text.startIndex, to: range.lowerBound))
            boundaries.insert(text.distance(from: text.startIndex, to: range.upperBound))
            return true
        }
        var cuts: [(offset: Int, penalty: Double)] = []
        for offset in 1..<characters.count {
            let after = characters[offset], before = characters[offset - 1]
            // A line never starts with a space, punctuation or a closing mark, nor ends with an opening one.
            guard !after.isWhitespace, !after.isPunctuation || openers.contains(after), !closers.contains(after),
                  !openers.contains(before) else { continue }
            guard boundaries.contains(offset) || before.isWhitespace else { continue }
            var back = offset - 1
            while back > 0, characters[back].isWhitespace || closers.contains(characters[back]) { back -= 1 }
            let mark = characters[back]
            cuts.append((offset, strong.contains(mark) ? 0 : weak.contains(mark) ? 0.05 : 0.25))
        }
        return cuts
    }

    private static func width(_ character: Character) -> Int {
        character.unicodeScalars.first.map(SubtitleLineMode.isWide) == true ? 2 : 1
    }
}
