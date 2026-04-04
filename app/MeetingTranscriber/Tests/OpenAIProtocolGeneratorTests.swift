@testable import MeetingTranscriber
import XCTest

final class OpenAIProtocolGeneratorTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // MARK: - SSE Line Parsing

    func testParseSSELineExtractsContent() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(OpenAIProtocolGenerator.parseSSELine(line), "Hello")
    }

    func testParseSSELineDoneReturnsNil() {
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine("data: [DONE]"))
    }

    func testParseSSELineEmptyDelta() {
        let line = #"data: {"choices":[{"delta":{}}]}"#
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine(line))
    }

    func testParseSSELineInvalidJSON() {
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine("data: not json"))
    }

    func testParseSSELineEmptyLine() {
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine(""))
    }

    func testParseSSELineComment() {
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine(": keepalive"))
    }

    func testParseSSELineNoDataPrefix() {
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine("event: message"))
    }

    func testParseSSELineMultipleChoices() {
        // Should extract from first choice
        let line = #"data: {"choices":[{"delta":{"content":"A"}},{"delta":{"content":"B"}}]}"#
        XCTAssertEqual(OpenAIProtocolGenerator.parseSSELine(line), "A")
    }

    func testParseSSELineRoleDelta() {
        // Role-only delta (first chunk) has no content
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine(line))
    }

    func testParseSSELineEmptyContent() {
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        XCTAssertEqual(OpenAIProtocolGenerator.parseSSELine(line), "")
    }

    // MARK: - Prompt Construction

    func testPromptContainsSystemInstructions() {
        // Verify the protocol prompt includes key structural elements
        let prompt = ProtocolGenerator.protocolPrompt
        XCTAssertTrue(prompt.contains("meeting minute taker"))
        XCTAssertTrue(prompt.contains("{LANGUAGE}"))
        XCTAssertTrue(prompt.contains("Markdown"))
    }

    func testPromptIncludesDiarizationNote() {
        let note = ProtocolGenerator.diarizationNote
        XCTAssertTrue(note.contains("speaker labels"))
        XCTAssertTrue(note.contains("SPEAKER_00"))
    }

    // MARK: - Initializer

    func testDefaultTimeout() throws {
        let gen = try OpenAIProtocolGenerator(
            endpoint: XCTUnwrap(URL(string: "http://localhost:11434/v1/chat/completions")),
            model: "test",
            language: "German",
        )
        XCTAssertEqual(gen.timeoutSeconds, 600)
    }

    func testCustomTimeout() throws {
        let gen = try OpenAIProtocolGenerator(
            endpoint: XCTUnwrap(URL(string: "http://localhost:11434/v1/chat/completions")),
            model: "test",
            language: "German",
            timeoutSeconds: 120,
        )
        XCTAssertEqual(gen.timeoutSeconds, 120)
    }

    func testAPIKeyOptional() throws {
        let gen = try OpenAIProtocolGenerator(
            endpoint: XCTUnwrap(URL(string: "http://localhost:11434/v1/chat/completions")),
            model: "test",
            language: "German",
        )
        XCTAssertNil(gen.apiKey)
    }

    // MARK: - SSE Multi-Line Joining

    func testParseMultipleSSELinesJoined() {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"content":" world"}}]}"#,
            "data: [DONE]",
        ]
        let parts = lines.compactMap { OpenAIProtocolGenerator.parseSSELine($0) }
        let result = parts.joined()
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - ProtocolError Descriptions

    func testEmptyProtocolErrorDescription() {
        let error = ProtocolError.emptyProtocol
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("empty"), "Expected 'empty' in: \(description)")
    }

    func testHttpErrorDescription() {
        let error = ProtocolError.httpError(503, "Service Unavailable")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("503"), "Expected status code in: \(description)")
        XCTAssertTrue(description.contains("Service Unavailable"), "Expected body in: \(description)")
    }

    func testHttpErrorEmptyBody() {
        let error = ProtocolError.httpError(500, "")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("500"), "Expected status code in: \(description)")
        XCTAssertFalse(description.hasSuffix(": "), "Should not end with colon-space for empty body")
    }

    func testConnectionFailedErrorDescription() {
        let error = ProtocolError.connectionFailed("timeout reached")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("timeout reached"), "Expected reason in: \(description)")
        XCTAssertTrue(description.contains("Connection failed"), "Expected prefix in: \(description)")
    }

    // MARK: - Language Substitution

    func testApplyLanguageSubstitution() {
        let template = "Write the protocol in {LANGUAGE}. Use {LANGUAGE} consistently."
        let result = ProtocolGenerator.applyLanguage(template, language: "French")
        XCTAssertEqual(result, "Write the protocol in French. Use French consistently.")
        XCTAssertFalse(result.contains("{LANGUAGE}"))
    }

    // MARK: - generate() via MockURLProtocol

    // swiftlint:disable:next force_unwrapping
    private static let testEndpoint = URL(string: "http://test.local/v1/chat/completions")!
    private static let okSSE = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\ndata: [DONE]\n"

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeGenerator(session: URLSession, apiKey: String? = nil) -> OpenAIProtocolGenerator {
        OpenAIProtocolGenerator(
            endpoint: Self.testEndpoint,
            model: "test-model",
            language: "German",
            apiKey: apiKey,
            session: session,
        )
    }

    private func mockResponse(_ request: URLRequest, status: Int = 200, body: Data = Data()) -> (HTTPURLResponse, Data) {
        // swiftlint:disable:next force_unwrapping
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, body)
    }

    func testGenerateSuccessfulSSEStream() async throws {
        let sseBody = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}
        data: {"choices":[{"delta":{"content":"# Protocol"}}]}
        data: {"choices":[{"delta":{"content":"\\nContent here"}}]}
        data: [DONE]
        """
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return self.mockResponse(request, body: Data(sseBody.utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        let result = try await gen.generate(transcript: "Test transcript", title: "Test", diarized: false)
        XCTAssertTrue(result.contains("Protocol"))
        XCTAssertTrue(result.contains("Content here"))
    }

    func testGenerateSetsAuthorizationHeader() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = makeGenerator(session: makeMockSession(), apiKey: "sk-test-123")
        _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
    }

    func testGenerateNoAuthHeaderWhenKeyNil() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
    }

    func testGenerateDiarizedDoesNotThrow() async throws {
        MockURLProtocol.handler = { request in
            self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        let result = try await gen.generate(transcript: "Test", title: "Test", diarized: true)
        XCTAssertFalse(result.isEmpty)
    }

    func testGenerateHTTPErrorThrows() async throws {
        MockURLProtocol.handler = { request in
            self.mockResponse(request, status: 503, body: Data("Service Unavailable".utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        do {
            _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
            XCTFail("Expected httpError")
        } catch let error as ProtocolError {
            if case let .httpError(code, body) = error {
                XCTAssertEqual(code, 503)
                XCTAssertTrue(body.contains("Service Unavailable"))
            } else {
                XCTFail("Expected httpError, got \(error)")
            }
        }
    }

    func testGenerateEmptyResponseThrows() async throws {
        MockURLProtocol.handler = { request in
            self.mockResponse(request, body: Data("data: [DONE]\n".utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        do {
            _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
            XCTFail("Expected emptyProtocol")
        } catch let error as ProtocolError {
            if case .emptyProtocol = error { /* expected */ } else {
                XCTFail("Expected emptyProtocol, got \(error)")
            }
        }
    }

    // MARK: - testConnection() via MockURLProtocol

    func testTestConnectionSuccess() async {
        let modelsJSON = #"{"data":[{"id":"llama3"},{"id":"mistral"}]}"#
        MockURLProtocol.handler = { request in
            self.mockResponse(request, body: Data(modelsJSON.utf8))
        }

        let result = await OpenAIProtocolGenerator.testConnection(
            endpoint: "http://test.local/v1/chat/completions",
            model: "test",
            apiKey: nil,
            session: makeMockSession(),
        )
        if case let .success(models) = result {
            XCTAssertEqual(models, ["llama3", "mistral"])
        } else {
            XCTFail("Expected success")
        }
    }

    func testTestConnectionHTTPError() async {
        MockURLProtocol.handler = { request in
            self.mockResponse(request, status: 401)
        }

        let result = await OpenAIProtocolGenerator.testConnection(
            endpoint: "http://test.local/v1/chat/completions",
            model: "test",
            apiKey: nil,
            session: makeMockSession(),
        )
        if case let .failure(error) = result, let pe = error as? ProtocolError, case let .httpError(code, _) = pe {
            XCTAssertEqual(code, 401)
        } else {
            XCTFail("Expected httpError(401)")
        }
    }

    func testTestConnectionInvalidEndpoint() async {
        let result = await OpenAIProtocolGenerator.testConnection(
            endpoint: "",
            model: "test",
            apiKey: nil,
        )
        if case .failure = result { /* expected */ } else {
            XCTFail("Expected failure for empty endpoint")
        }
    }
}

// MARK: - MockURLProtocol

private class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
