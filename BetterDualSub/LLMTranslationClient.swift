import Foundation

/// Services with an OpenAI-compatible chat API. Local ones (Ollama, LM Studio) keep subtitle text on this Mac.
nonisolated enum LLMPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama, lmStudio, openAI, deepSeek, custom

    var id: String { rawValue }

    var baseURL: String {
        switch self {
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .custom: ""
        }
    }

    var name: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .custom: subtitleLocalizedString("llm.preset.custom")
        }
    }
}

/// How to reach the language model that translates subtitles. The API key is kept in the keychain (`KeychainStore`).
nonisolated struct LLMConfiguration: Codable, Equatable, Sendable {
    static let storageKey = "llmConfiguration"
    static let batchSizes = 5...60
    static let contextSizes = 0...30

    var preset = LLMPreset.ollama
    var baseURL = LLMPreset.ollama.baseURL
    var model = ""
    var temperature = 0.3
    /// Sentences per request.
    var batchSize = 20
    /// Translated sentences before a batch, and untranslated ones after it, sent along for context.
    var contextLines = 8
    /// The user's own instructions: style, the show's premise, how to address people.
    var instructions = ""
    /// Off: people's names stay as written in the original, as do place names below; glossary entries the user wrote
    /// are still followed.
    var translateNames = true
    var translatePlaces = true
    /// Keep -san, -kun, oppa and the like rather than replacing them with forms of address of the target language.
    var keepHonorifics = false
    var softenProfanity = false
    /// The `LLMPromptTemplate` that sets the translator's role and style.
    var promptID = LLMPromptTemplate.standard.id

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LLMConfiguration()
        preset = (try? container.decodeIfPresent(LLMPreset.self, forKey: .preset)) ?? defaults.preset
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? defaults.batchSize
        contextLines = try container.decodeIfPresent(Int.self, forKey: .contextLines) ?? defaults.contextLines
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? defaults.instructions
        translateNames = try container.decodeIfPresent(Bool.self, forKey: .translateNames) ?? defaults.translateNames
        translatePlaces = try container.decodeIfPresent(Bool.self, forKey: .translatePlaces) ?? defaults.translatePlaces
        keepHonorifics = try container.decodeIfPresent(Bool.self, forKey: .keepHonorifics) ?? defaults.keepHonorifics
        softenProfanity = try container.decodeIfPresent(Bool.self, forKey: .softenProfanity) ?? defaults.softenProfanity
        promptID = try container.decodeIfPresent(String.self, forKey: .promptID) ?? defaults.promptID
    }

    static func load(from defaults: UserDefaults = .standard) -> LLMConfiguration {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(LLMConfiguration.self, from: $0) } ?? LLMConfiguration()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }

    /// The API root, such as `http://localhost:11434/v1`, when it is a usable http(s) URL.
    var endpoint: URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }

    /// Kinds of glossary entry left untranslated, whose entries found by the model are not used.
    var untranslatedKinds: Set<GlossaryEntry.Kind> {
        Set([translateNames ? nil : GlossaryEntry.Kind.person, translatePlaces ? nil : .place].compactMap { $0 })
    }

    var isComplete: Bool { endpoint != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Host and port, which name the API key in the keychain.
    var keychainAccount: String {
        guard let endpoint, let host = endpoint.host() else { return "" }
        return endpoint.port.map { "\(host):\($0)" } ?? host
    }

    /// Whether requests stay on this Mac.
    var isOnThisMac: Bool {
        guard let host = endpoint?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.") || host.hasSuffix(".localhost")
    }

    var apiKey: String? { KeychainStore.password(account: keychainAccount) }
}

nonisolated struct LLMChatMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String

    static func system(_ content: String) -> Self { Self(role: "system", content: content) }
    static func user(_ content: String) -> Self { Self(role: "user", content: content) }
}

nonisolated enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case http(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: subtitleLocalizedString("llm.error.notConfigured")
        case .http(let status, let message):
            subtitleLocalizedFormat("llm.error.http", status, message.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : message)
        case .invalidResponse: subtitleLocalizedString("llm.error.invalidResponse")
        }
    }

    /// The service refused a JSON-mode request, which not every OpenAI-compatible server supports.
    var rejectsJSONMode: Bool {
        guard case .http(let status, let message) = self else { return false }
        return status == 400 || status == 422 ? message.localizedCaseInsensitiveContains("response_format") || message.isEmpty : false
    }
}

/// A minimal client for `/chat/completions` and `/models` of an OpenAI-compatible API.
nonisolated struct LLMTranslationClient: Sendable {
    let configuration: LLMConfiguration
    let apiKey: String?
    var session: URLSession = .shared
    /// Waits before each retry of a rate-limited, failed or timed-out request.
    var retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(12)]

    private nonisolated struct ChatRequest: Encodable {
        nonisolated struct Format: Encodable { let type: String }
        let model: String
        let messages: [LLMChatMessage]
        let temperature: Double
        let stream = false
        let response_format: Format?
    }

    private nonisolated struct ChatResponse: Decodable {
        nonisolated struct Choice: Decodable {
            nonisolated struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private nonisolated struct ErrorResponse: Decodable {
        nonisolated struct Detail: Decodable { let message: String? }
        let error: Detail?
        let message: String?
    }

    private nonisolated struct ModelList: Decodable {
        nonisolated struct Model: Decodable { let id: String }
        let data: [Model]
    }

    /// The reply to `messages`. `jsonMode` asks the service for a JSON object, where it supports that.
    func complete(_ messages: [LLMChatMessage], jsonMode: Bool) async throws -> String {
        guard let endpoint = configuration.endpoint, configuration.isComplete else { throw LLMError.notConfigured }
        var request = makeRequest(endpoint.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), messages: messages,
            temperature: configuration.temperature, response_format: jsonMode ? .init(type: "json_object") : nil))
        let data = try await send(request)
        guard let content = try? JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content,
              !content.isEmpty else { throw LLMError.invalidResponse }
        return content
    }

    /// Model identifiers the service offers, for the settings page.
    func models() async throws -> [String] {
        guard let endpoint = configuration.endpoint else { throw LLMError.notConfigured }
        let data = try await send(makeRequest(endpoint.appendingPathComponent("models")), retries: false)
        guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else { throw LLMError.invalidResponse }
        return list.data.map(\.id).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest, retries: Bool = true) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
                if (200..<300).contains(http.statusCode) { return data }
                let error = LLMError.http(status: http.statusCode, message: Self.message(in: data))
                guard retries, http.statusCode == 429 || http.statusCode >= 500, attempt < retryDelays.count else { throw error }
            } catch let error as URLError where retries && [.timedOut, .networkConnectionLost].contains(error.code) && attempt < retryDelays.count {
                // A busy local model can take longer than the timeout; try again rather than lose the whole track.
            }
            try await Task.sleep(for: retryDelays[attempt])
            attempt += 1
        }
    }

    private static func message(in data: Data) -> String {
        let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        let text = decoded?.error?.message ?? decoded?.message ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JSON object in a model's reply, which may wrap it in a Markdown code fence or a sentence.
    static func jsonObject(in reply: String) -> Any? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.range(of: "```") {
            let body = String(text[open.upperBound...].drop { $0 != "\n" })
            text = body.components(separatedBy: "```").first ?? body
        }
        let starts = [text.firstIndex(of: "{"), text.firstIndex(of: "[")].compactMap { $0 }
        guard let start = starts.min() else { return nil }
        let closer: Character = text[start] == "{" ? "}" : "]"
        guard let end = text.lastIndex(of: closer), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))
    }
}
