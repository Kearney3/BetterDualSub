import Foundation

/// Translates subtitles with a language model behind an OpenAI-compatible API: whole sentences with the lines around
/// them, the show's glossary, and each sentence's split over its cues kept in the reply.
@MainActor
final class LLMSubtitleTranslationSession: SubtitleTranslationSession {
    private let client: LLMTranslationClient
    private let source: Locale.Language
    private let target: Locale.Language
    /// Cleared once the service turns down JSON mode, so later requests do not ask again.
    private var jsonMode = true

    init(client: LLMTranslationClient, source: Locale.Language, target: Locale.Language) {
        self.client = client
        self.source = source
        self.target = target
    }

    var understandsContext: Bool { true }

    func translate(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext,
                   receive: (SubtitleTranslationOutput) throws -> Void) async throws {
        var translations = try await request(inputs, context: context)
        // Models now and then skip a line of a long batch; one more request for just those usually brings them back.
        let missing = inputs.filter { translations[$0.index] == nil }
        if !missing.isEmpty {
            try await request(missing, context: context).forEach { translations[$0.key] = $0.value }
        }
        for input in inputs {
            guard let segments = translations[input.index] else { continue }
            try Task.checkCancellation()
            let text = segments.dropFirst().reduce(segments.first ?? "", SubtitleLineMode.join)
            try receive(SubtitleTranslationOutput(identifier: String(input.index), text: text, segments: segments))
        }
    }

    func extractTerms(_ lines: [String], known: [GlossaryEntry]) async throws -> [GlossaryEntry] {
        let payload: [String: Any] = [
            "known": known.map { ["source": $0.source, "target": $0.target] },
            "lines": lines,
        ]
        let reply = try await complete([.system(termPrompt), .user(Self.json(payload))])
        guard let object = LLMTranslationClient.jsonObject(in: reply) else { return [] }
        let terms = (object as? [String: Any])?["terms"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
        return terms.compactMap { term in
            guard let source = term["source"] as? String, let target = term["target"] as? String else { return nil }
            let kind = (term["kind"] as? String).flatMap { GlossaryEntry.Kind(rawValue: $0.lowercased()) } ?? .term
            return GlossaryEntry(source: source, target: target, kind: kind, automatic: true)
        }
    }

    func cancel() {}

    // MARK: Requests

    /// Translations by input index; lines the reply left out are missing.
    private func request(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext) async throws -> [Int: [String]] {
        var payload: [String: Any] = ["lines": inputs.map { ["id": $0.index, "segments": $0.segments] as [String: Any] }]
        if !context.glossary.isEmpty {
            payload["glossary"] = context.glossary.map { ["source": $0.source, "target": $0.target] }
        }
        if !context.preceding.isEmpty {
            payload["context_before"] = context.preceding.map { ["source": $0.source, "translation": $0.translation] }
        }
        if !context.following.isEmpty { payload["context_after"] = context.following }
        let reply = try await complete([.system(translationPrompt(strict: context.strict)), .user(Self.json(payload))])
        return Self.translations(in: reply, expected: Set(inputs.map(\.index)))
    }

    private func complete(_ messages: [LLMChatMessage]) async throws -> String {
        do {
            return try await client.complete(messages, jsonMode: jsonMode)
        } catch let error as LLMError where jsonMode && error.rejectsJSONMode {
            jsonMode = false
            return try await client.complete(messages, jsonMode: false)
        }
    }

    /// Reads `{"translations": [{"id": 3, "segments": ["…"]}]}`, also accepting a bare list, string ids and a single
    /// `text` in place of segments.
    static func translations(in reply: String, expected: Set<Int>) -> [Int: [String]] {
        guard let object = LLMTranslationClient.jsonObject(in: reply) else { return [:] }
        let list = (object as? [String: Any])?["translations"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
        var result: [Int: [String]] = [:]
        for entry in list {
            let id = entry["id"] as? Int ?? (entry["id"] as? String).flatMap { Int($0) }
            guard let id, expected.contains(id), result[id] == nil else { continue }
            let segments = (entry["segments"] as? [Any])?.compactMap { $0 as? String }
                ?? (entry["text"] as? String).map { [$0] } ?? (entry["segments"] as? String).map { [$0] }
            guard let segments, segments.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            result[id] = segments
        }
        return result
    }

    private static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Prompts

    private var instructions: String {
        let text = client.configuration.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : "\n\nInstructions from the viewer (follow them unless they break the reply format):\n\(text)"
    }

    /// The viewer's choices on the settings page, as more rules of the translation prompt.
    private func styleRules(_ to: String) -> String {
        let configuration = client.configuration
        var rules: [String] = []
        if !configuration.translateNames {
            rules.append("Do not translate or transliterate people's names and nicknames: write them exactly as in the original " +
                         "lines, unless \"glossary\" lists them.")
        }
        if !configuration.translatePlaces {
            rules.append("Do not translate or transliterate place names: write them exactly as in the original lines, unless " +
                         "\"glossary\" lists them.")
        }
        if configuration.keepHonorifics {
            rules.append("Keep honorifics and forms of address such as -san, -kun, -chan, -sama, senpai, oppa and unnie rather " +
                         "than replacing them with \(to) ones; write them the way \(to) subtitles of such shows usually do.")
        }
        if configuration.softenProfanity {
            rules.append("Tone down swearing, slurs and crude words to mild wording that keeps the speaker's feeling.")
        }
        return rules.map { "\n- " + $0 }.joined()
    }

    private func translationPrompt(strict: Bool) -> String {
        let from = Self.englishName(source), to = Self.englishName(target)
        var prompt = """
        You are a professional subtitle translator. Translate film and TV subtitles from \(from) into \(to).

        Each item of "lines" has an "id" and "segments": the consecutive subtitle cues one sentence is spoken over. \
        Translate the sentence as a whole, then return it as the same number of segments, in the same order, so that \
        each translated segment can be shown while its original segment is spoken. Only move words between segments \
        when \(to) word order requires it, and never leave a segment empty unless the sentence is shorter than its segments.

        - Write natural, concise, spoken \(to) that reads well as subtitles. Keep each speaker's tone, register and humor.
        - Always translate names and terms listed in "glossary" exactly as given there.
        - Keep other names, places and recurring terms consistent with "context_before".
        - "context_before" (already translated) and "context_after" are only there to help you understand; do not \
        translate or return them.
        - Do not add notes, explanations, quotes around lines or romanization. Keep ♪ and numbers as they are.\(styleRules(to))

        Reply with JSON only, in this form:
        {"translations":[{"id":0,"segments":["…"]}]}
        Include every id of "lines" exactly once.
        """
        if strict {
            prompt += "\n\nThe previous translation of these lines did not use the glossary. Every glossary term that " +
                "occurs in a line must appear in its translation exactly as written in \"glossary\"."
        }
        return prompt + instructions
    }

    private var termPrompt: String {
        let from = Self.englishName(source), to = Self.englishName(target)
        return """
        You prepare the glossary for translating the subtitles of one film or TV show from \(from) into \(to).

        From "lines", list the names of people, places and organizations, and the terms particular to this show: \
        titles, ranks, nicknames, invented words, named objects. Leave out ordinary words. For each, give the \(to) \
        rendering a professional subtitle translator would use, preferring an established official translation. \
        Entries in "known" are already settled: do not list them again, and keep related names consistent with them.

        Reply with JSON only, in this form:
        {"terms":[{"source":"…","target":"…","kind":"person|place|organization|term"}]}
        """ + instructions
    }

    /// The language's English name, which models understand best; Chinese is told apart by script.
    static func englishName(_ language: Locale.Language) -> String {
        let english = Locale(identifier: "en")
        if language.languageCode == .chinese {
            return Locale.Language(identifier: language.maximalIdentifier).script == .hanTraditional
                ? "Traditional Chinese" : "Simplified Chinese"
        }
        return language.languageCode.flatMap { english.localizedString(forLanguageCode: $0.identifier) } ?? language.minimalIdentifier
    }
}
