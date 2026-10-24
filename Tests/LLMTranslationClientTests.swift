import XCTest
@testable import BetterDualSubCore

/// Answers requests of a test URLSession from a queue of canned responses, recording what was sent.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func session(_ responses: [(Int, String)]) -> URLSession {
        self.responses = responses.map { (status: $0.0, body: $0.1) }
        requests = []
        bodies = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated(unsafe) static var bodies: [Data] = []

    static func body(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: bodies[index])) as? [String: Any] ?? [:]
    }

    /// URLSession hands the body to protocols as a stream, which can be read only once.
    private static func read(_ request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.read(request))
        let next = Self.responses.isEmpty ? (status: 500, body: "{}") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func chat(_ content: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    return String(data: data, encoding: .utf8)!
}

@MainActor
final class LLMTranslationClientTests: XCTestCase {
    private var configuration: LLMConfiguration {
        var configuration = LLMConfiguration()
        configuration.preset = .custom
        configuration.baseURL = "https://llm.example.com/v1/"
        configuration.model = "test-model"
        return configuration
    }

    private func client(_ responses: [(Int, String)], apiKey: String? = "secret") -> LLMTranslationClient {
        var client = LLMTranslationClient(configuration: configuration, apiKey: apiKey, session: StubURLProtocol.session(responses))
        client.retryDelays = [.zero, .zero]
        return client
    }

    func testCompletionSendsModelMessagesAndKey() async throws {
        let reply = try await client([(200, chat("你好"))]).complete([.system("Translate."), .user("Hello")], jsonMode: true)
        XCTAssertEqual(reply, "你好")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = StubURLProtocol.body(0)
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] ?? "" }, ["system", "user"])
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
    }

    func testRateLimitsAndServerErrorsAreRetriedButOtherErrorsAreNot() async throws {
        let reply = try await client([(429, "{}"), (503, "{}"), (200, chat("ok"))]).complete([.user("x")], jsonMode: false)
        XCTAssertEqual(reply, "ok")
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        do {
            _ = try await client([(401, #"{"error":{"message":"Invalid API key"}}"#)]).complete([.user("x")], jsonMode: false)
            XCTFail("Expected an error")
        } catch let error as LLMError {
            XCTAssertEqual(error, .http(status: 401, message: "Invalid API key"))
            XCTAssertEqual(StubURLProtocol.requests.count, 1)
        }
    }

    func testModelsAreListedWithoutAKeyForLocalServers() async throws {
        let models = try await client([(200, #"{"data":[{"id":"qwen2.5:7b"},{"id":"llama3.1:8b"}]}"#)], apiKey: nil).models()
        XCTAssertEqual(models, ["llama3.1:8b", "qwen2.5:7b"])
        XCTAssertNil(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path(), "/v1/models")
    }

    func testRepliesAreReadFromFencesAndLooseShapes() {
        let fenced = "Here you go:\n```json\n{\"translations\":[{\"id\":\"2\",\"segments\":[\"甲\",\"乙\"]},{\"id\":3,\"text\":\"丙\"},{\"id\":9,\"text\":\"x\"}]}\n```"
        XCTAssertEqual(LLMSubtitleTranslationSession.translations(in: fenced, expected: [2, 3]), [2: ["甲", "乙"], 3: ["丙"]])
        XCTAssertEqual(LLMSubtitleTranslationSession.translations(in: #"[{"id":1,"segments":["  "]}]"#, expected: [1]), [:])
        XCTAssertEqual(LLMSubtitleTranslationSession.translations(in: "not json", expected: [1]), [:])
    }

    func testConfigurationKnowsWhetherRequestsStayOnThisMac() {
        var configuration = LLMConfiguration()
        XCTAssertTrue(configuration.isOnThisMac)
        XCTAssertFalse(configuration.isComplete, "A model is required.")
        configuration.baseURL = "http://192.168.1.20:1234/v1"
        configuration.model = "m"
        XCTAssertFalse(configuration.isOnThisMac)
        XCTAssertTrue(configuration.isComplete)
        XCTAssertEqual(configuration.keychainAccount, "192.168.1.20:1234")
        configuration.baseURL = "ftp://example.com"
        XCTAssertNil(configuration.endpoint)
        let decoded = try? JSONDecoder().decode(LLMConfiguration.self, from: Data(#"{"model":"x"}"#.utf8))
        XCTAssertEqual(decoded?.model, "x")
        XCTAssertEqual(decoded?.batchSize, LLMConfiguration().batchSize)
        XCTAssertEqual(decoded?.translateNames, true, "Settings saved before the option existed translate names.")
        XCTAssertEqual(decoded?.untranslatedKinds, [])
    }

    func testStyleChoicesBecomeRulesOfTheTranslationPrompt() async throws {
        func systemPrompt(_ change: (inout LLMConfiguration) -> Void) async throws -> String {
            var configuration = configuration
            change(&configuration)
            let reply = chat(#"{"translations":[{"id":0,"segments":["好。"]}]}"#)
            let client = LLMTranslationClient(configuration: configuration, apiKey: nil, session: StubURLProtocol.session([(200, reply)]))
            let session = LLMSubtitleTranslationSession(client: client, source: Locale.Language(identifier: "en"),
                                                        target: Locale.Language(identifier: "zh-Hans"))
            try await session.translate([SubtitleTranslationInput(index: 0, text: "Fine.")], context: SubtitleTranslationContext()) { _ in }
            return try XCTUnwrap((StubURLProtocol.body(0)["messages"] as? [[String: String]])?.first?["content"])
        }
        let plain = try await systemPrompt { _ in }
        for rule in ["people's names", "place names", "honorifics", "swearing"] { XCTAssertFalse(plain.contains(rule), rule) }
        let styled = try await systemPrompt {
            $0.translateNames = false
            $0.translatePlaces = false
            $0.keepHonorifics = true
            $0.softenProfanity = true
        }
        for rule in ["people's names", "place names", "honorifics", "swearing"] { XCTAssertTrue(styled.contains(rule), rule) }
        XCTAssertLessThan(try XCTUnwrap(styled.range(of: "swearing")).lowerBound, try XCTUnwrap(styled.range(of: "Reply with JSON")).lowerBound,
                          "The rules come before the reply format.")
    }

    func testSessionKeepsSegmentsRetriesMissingLinesAndDropsJSONModeWhenRefused() async throws {
        let first = chat(#"{"translations":[{"id":0,"segments":["我觉得","我们不该去。"]}]}"#)
        let second = chat(#"{"translations":[{"id":1,"segments":["好吧。"]}]}"#)
        let session = LLMSubtitleTranslationSession(
            client: client([(400, #"{"error":{"message":"response_format is not supported"}}"#), (200, first), (200, second)]),
            source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        var context = SubtitleTranslationContext()
        context.preceding = [(source: "Walter?", translation: "沃尔特？")]
        context.following = ["Later."]
        context.glossary = [GlossaryEntry(source: "Walter", target: "沃尔特")]
        var outputs: [SubtitleTranslationOutput] = []
        try await session.translate([
            SubtitleTranslationInput(index: 0, text: "I don't think we should go.", segments: ["I don't think", "we should go."]),
            SubtitleTranslationInput(index: 1, text: "Fine."),
        ], context: context) { outputs.append($0) }
        XCTAssertEqual(outputs.map(\.identifier), ["0", "1"])
        XCTAssertEqual(outputs.map(\.segments), [["我觉得", "我们不该去。"], ["好吧。"]])
        XCTAssertEqual(outputs.first?.text, "我觉得我们不该去。")
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertNotNil(StubURLProtocol.body(0)["response_format"])
        XCTAssertNil(StubURLProtocol.body(1)["response_format"])
        let user = try XCTUnwrap((StubURLProtocol.body(1)["messages"] as? [[String: String]])?.last?["content"])
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any])
        XCTAssertEqual((payload["glossary"] as? [[String: String]])?.first?["target"], "沃尔特")
        XCTAssertEqual((payload["context_before"] as? [[String: String]])?.first?["translation"], "沃尔特？")
        XCTAssertEqual(payload["context_after"] as? [String], ["Later."])
        XCTAssertEqual((payload["lines"] as? [[String: Any]])?.count, 2)
        let retry = try XCTUnwrap((StubURLProtocol.body(2)["messages"] as? [[String: String]])?.last?["content"])
        XCTAssertTrue(retry.contains("Fine.") && !retry.contains("I don't think"), "Only the missing line is asked for again.")
    }

    func testTermExtractionReadsKindsAndIgnoresMalformedEntries() async throws {
        let reply = chat(#"{"terms":[{"source":"Winterfell","target":"临冬城","kind":"Place"},{"source":"Jon"},{"source":"Night's Watch","target":"守夜人","kind":"guild"}]}"#)
        let session = LLMSubtitleTranslationSession(client: client([(200, reply)]), source: Locale.Language(identifier: "en"),
                                                    target: Locale.Language(identifier: "zh-Hans"))
        let terms = try await session.extractTerms(["Winter is coming to Winterfell."], known: [])
        XCTAssertEqual(terms.map(\.source), ["Winterfell", "Night's Watch"])
        XCTAssertEqual(terms.map(\.kind), [.place, .term])
        XCTAssertTrue(terms.allSatisfy(\.automatic))
    }
}
