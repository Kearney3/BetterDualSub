import Foundation

/// Translates subtitles with a language model behind an OpenAI-compatible API: whole sentences with the lines around
/// them, the show's glossary, and each sentence's split over its cues kept in the reply.
@MainActor
final class LLMSubtitleTranslationSession: SubtitleTranslationSession {
    private let client: LLMTranslationClient
    private let source: Locale.Language
    private let target: Locale.Language
    private let prompt: LLMPromptTemplate
    /// Cleared once the service turns down JSON mode, so later requests do not ask again.
    private var jsonMode = true

    init(client: LLMTranslationClient, source: Locale.Language, target: Locale.Language, prompt: LLMPromptTemplate = .standard) {
        self.client = client
        self.source = source
        self.target = target
        self.prompt = prompt
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
        let reply = try await complete([.system(Self.termPrompt(from: Self.englishName(source), to: Self.englishName(target),
                                                                     configuration: client.configuration)), .user(Self.json(payload))])
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
        let reply = try await complete([.system(Self.translationPrompt(prompt, from: Self.englishName(source), to: Self.englishName(target),
                                                                            configuration: client.configuration, strict: context.strict)), .user(Self.json(payload))])
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

    private static func instructions(_ configuration: LLMConfiguration) -> String {
        let text = configuration.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : "\n\nInstructions from the viewer (follow them unless they break the reply format):\n\(text)"
    }

    /// The viewer's choices on the settings page, as more rules of the translation prompt.
    private static func styleRules(_ configuration: LLMConfiguration, to: String) -> String {
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

    /// The system prompt of a translation request: the template's role and style, then the app's own rules for segments,
    /// glossary, context and the reply, which every template keeps so replies stay readable.
    static func translationPrompt(_ template: LLMPromptTemplate, from: String, to: String, configuration: LLMConfiguration,
                                  strict: Bool = false) -> String {
        var prompt = template.resolved(source: from, target: to) + """


        Each item of "lines" has an "id" and "segments": the consecutive subtitle cues one sentence is spoken over. \
        Translate the sentence as a whole, then return it as the same number of segments, in the same order, so that \
        each translated segment can be shown while its original segment is spoken. Only move words between segments \
        when \(to) word order requires it, and never leave a segment empty unless the sentence is shorter than its segments.

        - Always translate names and terms listed in "glossary" exactly as given there.
        - Keep other names, places and recurring terms consistent with "context_before".
        - "context_before" (already translated) and "context_after" are only there to help you understand; do not \
        translate or return them.
        - Do not add notes, explanations, quotes around lines or romanization. Keep ♪ and numbers as they are.\(styleRules(configuration, to: to))

        Reply with JSON only, in this form:
        {"translations":[{"id":0,"segments":["…"]}]}
        Include every id of "lines" exactly once.
        """
        if strict {
            prompt += "\n\nThe previous translation of these lines did not use the glossary. Every glossary term that " +
                "occurs in a line must appear in its translation exactly as written in \"glossary\"."
        }
        return prompt + instructions(configuration)
    }

    /// The system prompt that gathers a show's names and terms.
    static func termPrompt(from: String, to: String, configuration: LLMConfiguration) -> String {
        """
        You prepare the glossary for translating the subtitles of one film or TV show from \(from) into \(to).

        From "lines", list the names of people, places and organizations, and the terms particular to this show: \
        titles, ranks, nicknames, invented words, named objects. Leave out ordinary words. For each, give the \(to) \
        rendering a professional subtitle translator would use, preferring an established official translation. \
        Entries in "known" are already settled: do not list them again, and keep related names consistent with them.

        Reply with JSON only, in this form:
        {"terms":[{"source":"…","target":"…","kind":"person|place|organization|term"}]}
        """ + instructions(configuration)
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

/// The translator's role and style at the top of the translation prompt, with `{source}` and `{target}` standing for
/// the languages. The app adds the rest itself (`LLMSubtitleTranslationSession.translationPrompt`).
nonisolated struct LLMPromptTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// The user's name for their own template; built-in ones are named in the interface language (`title`).
    var name: String
    var text: String

    var isBuiltIn: Bool { id.hasPrefix("builtin.") }
    var title: String { isBuiltIn ? subtitleLocalizedString("llm.prompt.\(id.dropFirst("builtin.".count))") : name }

    func resolved(source: String, target: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{source}", with: source)
            .replacingOccurrences(of: "{target}", with: target)
    }

    static let standard = LLMPromptTemplate(id: "builtin.standard", name: "", text: """
        You are a professional subtitle translator. Translate film and TV subtitles from {source} into {target}.

        Write natural, concise, spoken {target} that reads well as subtitles. Keep each speaker's tone, register and humor.
        """)

    static let faithful = LLMPromptTemplate(id: "builtin.faithful", name: "", text: """
        You are a careful subtitle translator for viewers who follow the original alongside the translation. Translate \
        film and TV subtitles from {source} into {target}.

        Stay close to the original wording and sentence structure, so each line can be compared with its source, as long \
        as the {target} stays correct and readable. Translate idioms by their meaning, and do not add, drop or embellish \
        anything.
        """)

    static let localized = LLMPromptTemplate(id: "builtin.localized", name: "", text: """
        You are an experienced subtitle localizer. Translate film and TV subtitles from {source} into {target} for an \
        audience who speaks {target}.

        Prefer what a native speaker would naturally say over a literal rendering. Render idioms, wordplay, jokes and \
        cultural references with {target} equivalents that land the same way, keep each character's slang and register, \
        and keep lines short enough to read at a glance.
        """)

    static let builtIn = [standard, faithful, localized]
}

/// The built-in prompt templates and the user's own, kept in user defaults.
nonisolated enum LLMPromptLibrary {
    static let storageKey = "llmPromptTemplates"

    static func custom(from defaults: UserDefaults = .standard) -> [LLMPromptTemplate] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([LLMPromptTemplate].self, from: $0) } ?? []
    }

    static func saveCustom(_ templates: [LLMPromptTemplate], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(templates.filter { !$0.isBuiltIn }) { defaults.set(data, forKey: storageKey) }
    }

    /// The template with `id`, or the standard one when it was deleted.
    static func template(id: String, defaults: UserDefaults = .standard) -> LLMPromptTemplate {
        (LLMPromptTemplate.builtIn + custom(from: defaults)).first { $0.id == id } ?? .standard
    }
}
