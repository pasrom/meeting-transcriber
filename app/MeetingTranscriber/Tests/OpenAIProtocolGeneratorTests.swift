// swiftlint:disable file_length
@testable import MeetingTranscriber
import os
import XCTest

final class OpenAIProtocolGeneratorTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle type_body_length
    // MARK: - SSE Line Parsing

    func testParseSSELineExtractsContent() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(OpenAIProtocolGenerator.parseSSELine(line)?.content, "Hello")
    }

    func testParseSSELineExtractsFinishReason() {
        let stop = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        XCTAssertEqual(OpenAIProtocolGenerator.parseSSELine(stop)?.finishReason, "stop")
        let length = #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#
        XCTAssertEqual(OpenAIProtocolGenerator.parseSSELine(length)?.finishReason, "length")
        // A content-only chunk carries no finish reason.
        let content = #"data: {"choices":[{"delta":{"content":"x"}}]}"#
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine(content)?.finishReason)
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
        XCTAssertEqual(OpenAIProtocolGenerator.parseSSELine(line)?.content, "A")
    }

    func testParseSSELineRoleDelta() {
        // Role-only delta (first chunk) has no content
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertNil(OpenAIProtocolGenerator.parseSSELine(line))
    }

    func testParseSSELineEmptyContent() {
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        XCTAssertEqual(OpenAIProtocolGenerator.parseSSELine(line)?.content, "")
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
        let parts = lines.compactMap { OpenAIProtocolGenerator.parseSSELine($0)?.content }
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

    // MARK: - Prompt Variable Substitution

    func testApplyVariablesSubstitutesLanguage() {
        let template = "Write the protocol in {LANGUAGE}. Use {LANGUAGE} consistently."
        let result = ProtocolGenerator.applyVariables(template, language: "French", metadata: nil)
        XCTAssertEqual(result, "Write the protocol in French. Use French consistently.")
        XCTAssertFalse(result.contains("{LANGUAGE}"))
    }

    // MARK: - generate() via MockURLProtocol

    private static let testEndpoint = URL(string: "http://test.local/v1/chat/completions")!
    private static let okSSE = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\ndata: [DONE]\n"

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
        MockURLProtocol.rawResponseHandler = nil
        MockURLProtocol.hangHandler = nil
        MockURLProtocol.redirectHandler = nil
        super.tearDown()
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeGenerator(
        session: URLSession,
        apiKey: String? = nil,
        apiKeyPlacement: OpenAIAPIKeyPlacement = .bearerToken,
        apiKeyHeaderName: String = "api-key",
    ) -> OpenAIProtocolGenerator {
        OpenAIProtocolGenerator(
            endpoint: Self.testEndpoint,
            model: "test-model",
            language: "German",
            apiKey: apiKey,
            apiKeyPlacement: apiKeyPlacement,
            apiKeyHeaderName: apiKeyHeaderName,
            session: session,
        )
    }

    private func mockResponse(_ request: URLRequest, status: Int = 200, body: Data = Data()) -> (HTTPURLResponse, Data) {
        // swiftlint:disable:next force_unwrapping
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, body)
    }

    /// Decode the JSON request body (empty on failure). URLSession converts
    /// `httpBody` to an `httpBodyStream` before the protocol sees it, so read
    /// whichever is set.
    private func requestBody(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            // Drive by read result, not hasBytesAvailable (which can be false
            // before the first read on some stream types).
            while true {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
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

    func testGenerateThrowsProtocolTruncatedOnLengthFinishReason() async {
        // The model emits content then a terminating chunk with finish_reason
        // "length" (hit max_tokens/context). The result must NOT be presented as
        // a clean completion.
        let sseBody = """
        data: {"choices":[{"delta":{"content":"# Partial protocol"}}]}
        data: {"choices":[{"delta":{},"finish_reason":"length"}]}
        data: [DONE]
        """
        MockURLProtocol.handler = { request in
            self.mockResponse(request, body: Data(sseBody.utf8))
        }
        let gen = makeGenerator(session: makeMockSession())
        do {
            _ = try await gen.generate(transcript: "x", title: "t", diarized: false)
            XCTFail("expected ProtocolError.protocolTruncated")
        } catch {
            guard case ProtocolError.protocolTruncated = error else {
                XCTFail("expected protocolTruncated, got \(error)")
                return
            }
        }
    }

    func testGenerateSucceedsOnStopFinishReason() async throws {
        let sseBody = """
        data: {"choices":[{"delta":{"content":"# Done"}}]}
        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
        data: [DONE]
        """
        MockURLProtocol.handler = { request in
            self.mockResponse(request, body: Data(sseBody.utf8))
        }
        let gen = makeGenerator(session: makeMockSession())
        let result = try await gen.generate(transcript: "x", title: "t", diarized: false)
        XCTAssertTrue(result.contains("Done"))
    }

    func testGenerateRequestIncludesMaxTokens() async throws {
        MockURLProtocol.handler = { request in
            let body = self.requestBody(request)
            XCTAssertNotNil(body["max_tokens"], "request must cap output with max_tokens")
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\ndata: [DONE]"
            return self.mockResponse(request, body: Data(sse.utf8))
        }
        let gen = makeGenerator(session: makeMockSession())
        _ = try await gen.generate(transcript: "x", title: "t", diarized: false)
    }

    func testGenerateRequestIncludesAuthoritativeMeetingMetadata() async throws {
        let startTime = try localDate(2026, 8, 21, 13, 28)
        MockURLProtocol.handler = { request in
            let body = self.requestBody(request)
            let response = self.mockResponse(request, body: Data(Self.okSSE.utf8))
            guard let messages = body["messages"] as? [[String: Any]],
                  let systemPrompt = messages.first?["content"] as? String else {
                XCTFail("Request must contain a system prompt")
                return response
            }
            XCTAssertTrue(systemPrompt.contains("Date: 2026-08-21"))
            XCTAssertTrue(systemPrompt.contains("Time: 13:28"))
            return response
        }

        let gen = makeGenerator(session: makeMockSession())
        _ = try await gen.generate(
            transcript: "x", title: "t", diarized: false, meetingStartTime: startTime,
        )
    }

    func testGenerateTimesOutWhenStreamNeverCompletes() async {
        // Endpoint delivers a chunk then stalls forever (the struggling-LLM
        // case). request.timeoutInterval is an idle timeout and would never fire
        // here once bytes arrive; only the total deadline can end it.
        MockURLProtocol.hangHandler = { request in
            // swiftlint:disable:next force_unwrapping
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n"
            return (response, Data(chunk.utf8))
        }
        let gen = OpenAIProtocolGenerator(
            endpoint: Self.testEndpoint,
            model: "test-model",
            language: "German",
            apiKey: nil,
            maxTotalSeconds: 0.3,
            session: makeMockSession(),
        )
        do {
            _ = try await gen.generate(transcript: "x", title: "t", diarized: false)
            XCTFail("expected a total-deadline timeout")
        } catch {
            guard case ProtocolError.generationTimedOut = error else {
                XCTFail("expected ProtocolError.generationTimedOut, got \(error)")
                return
            }
        }
    }

    func testGenerateSetsAuthorizationHeader() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = makeGenerator(session: makeMockSession(), apiKey: "sk-test-123")
        _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
    }

    func testGenerateSetsCustomAPIKeyHeaderWithoutBearerPrefix() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret-value")
            XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        // A name other than the default, so the configured name is what reaches the wire.
        let gen = makeGenerator(
            session: makeMockSession(),
            apiKey: "secret-value",
            apiKeyPlacement: .customHeader,
            apiKeyHeaderName: "x-api-key",
        )
        _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
    }

    func testGenerateTrimsWhitespaceAroundCustomAPIKeyHeaderName() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret-value")
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = makeGenerator(
            session: makeMockSession(),
            apiKey: "secret-value",
            apiKeyPlacement: .customHeader,
            apiKeyHeaderName: " x-api-key \n",
        )
        _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
    }

    func testGenerateRejectsInvalidCustomAPIKeyHeaderNameBeforeSending() async {
        let requests = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.handler = { request in
            requests.withLock { $0 += 1 }
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = makeGenerator(
            session: makeMockSession(),
            apiKey: "secret-value",
            apiKeyPlacement: .customHeader,
            apiKeyHeaderName: "Content-Length",
        )
        do {
            _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
            XCTFail("Expected an invalid-header failure")
        } catch let ProtocolError.connectionFailed(message) {
            XCTAssertTrue(message.contains("Invalid API key header name"), message)
        } catch {
            XCTFail("Expected ProtocolError.connectionFailed, got \(error)")
        }
        XCTAssertEqual(requests.withLock { $0 }, 0, "no request may leave with an unusable header name")
    }

    func testGenerateSendsNoKeyHeaderForCustomHeaderWithoutKey() async throws {
        for apiKey in [nil, ""] as [String?] {
            MockURLProtocol.handler = { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return self.mockResponse(request, body: Data(Self.okSSE.utf8))
            }

            let gen = makeGenerator(
                session: makeMockSession(),
                apiKey: apiKey,
                apiKeyPlacement: .customHeader,
                apiKeyHeaderName: "x-api-key",
            )
            _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
        }
    }

    func testGenerateNoAuthHeaderWhenKeyNil() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
    }

    func testCustomAPIKeyHeaderNameRejectsHeadersURLSessionOrTheConnectionOwns() {
        // URLSession overwrites or drops some of these, so the key never leaves;
        // the rest are sent verbatim and break the request itself.
        let reserved = ["Content-Type", "Content-Length", "Transfer-Encoding", "Host", "Connection", "Expect", "Upgrade"]
        for name in reserved {
            for variant in [name, name.lowercased(), name.uppercased()] {
                XCTAssertFalse(OpenAIProtocolGenerator.isValidAPIKeyHeaderName(variant), variant)
            }
        }
    }

    func testCustomAPIKeyHeaderNameAcceptsOrdinaryRequestHeaders() {
        for name in ["Authorization", "Cookie", "User-Agent", "Accept", "X-Custom", "X-API_Key", "api-key", "x-api-key"] {
            XCTAssertTrue(OpenAIProtocolGenerator.isValidAPIKeyHeaderName(name), name)
        }
    }

    func testCustomAPIKeyHeaderNameRejectsMalformedNames() {
        for name in ["", " ", "x api", "x\tapi", "x:api", "schl\u{00FC}ssel"] {
            XCTAssertFalse(OpenAIProtocolGenerator.isValidAPIKeyHeaderName(name), name)
        }
    }

    // MARK: - max_tokens / max_completion_tokens negotiation

    /// Verbatim 400 body returned by the OpenAI Chat Completions API (and Azure
    /// Foundry) for GPT-5-family models when `max_tokens` is sent.
    private static let unsupportedMaxTokensBody = """
    {"error":{"message":"Unsupported parameter: 'max_tokens' is not supported \
    with this model. Use 'max_completion_tokens' instead.",\
    "type":"invalid_request_error","param":"max_tokens",\
    "code":"unsupported_parameter"}}
    """

    func testRejectsMaxTokensMatchesUnsupportedParameterBody() {
        XCTAssertTrue(OpenAIProtocolGenerator.rejectsMaxTokens(Self.unsupportedMaxTokensBody))
    }

    func testRejectsMaxTokensIgnoresUnrelatedErrors() {
        XCTAssertFalse(
            OpenAIProtocolGenerator.rejectsMaxTokens(
                #"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#,
            ),
        )
        XCTAssertFalse(
            OpenAIProtocolGenerator.rejectsMaxTokens(
                #"{"error":{"message":"The model does not exist","param":"model"}}"#,
            ),
        )
        XCTAssertFalse(OpenAIProtocolGenerator.rejectsMaxTokens(""))
        // Only one of the two names present: a value error, not the rename.
        XCTAssertFalse(OpenAIProtocolGenerator.rejectsMaxTokens(
            #"{"error":{"message":"max_tokens is too large: 16000","param":"max_tokens"}}"#,
        ))
        XCTAssertFalse(OpenAIProtocolGenerator.rejectsMaxTokens(
            #"{"error":{"message":"Use max_completion_tokens for this model"}}"#,
        ))
    }

    func testGenerateRetriesWithMaxCompletionTokensWhenRejected() async throws {
        final class Recorder: @unchecked Sendable { var keys: [String] = [] }
        let recorder = Recorder()

        MockURLProtocol.handler = { request in
            if self.requestBody(request)["max_tokens"] != nil {
                recorder.keys.append("max_tokens")
                return self.mockResponse(
                    request, status: 400, body: Data(Self.unsupportedMaxTokensBody.utf8),
                )
            }
            let retryBody = self.requestBody(request)
            XCTAssertEqual(retryBody["max_completion_tokens"] as? Int, 16000)
            XCTAssertNil(retryBody["max_tokens"], "the retry must replace the cap, not add to it")
            recorder.keys.append("max_completion_tokens")
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        let result = try await gen.generate(transcript: "Test", title: "Test", diarized: false)

        XCTAssertEqual(result, "OK")
        XCTAssertEqual(recorder.keys, ["max_tokens", "max_completion_tokens"])
    }

    // MARK: - Sampling overrides

    private func makeSamplingGenerator(temperature: Double?, topP: Double?) -> OpenAIProtocolGenerator {
        OpenAIProtocolGenerator(
            endpoint: Self.testEndpoint,
            model: "test-model",
            language: "German",
            temperature: temperature,
            topP: topP,
            session: makeMockSession(),
        )
    }

    func testRequestBodyOmitsSamplingKeysWhenUnset() {
        let body = makeSamplingGenerator(temperature: nil, topP: nil)
            .requestBody(messages: [], tokenLimit: .maxTokens)

        XCTAssertNil(body["temperature"], "an unset override must leave the server default in place")
        XCTAssertNil(body["top_p"])
        XCTAssertEqual(body["max_tokens"] as? Int, 16000)
    }

    func testRequestBodyCarriesSamplingKeysWhenSet() {
        let body = makeSamplingGenerator(temperature: 0.3, topP: 0.9)
            .requestBody(messages: [], tokenLimit: .maxTokens)

        XCTAssertEqual(body["temperature"] as? Double, 0.3)
        XCTAssertEqual(body["top_p"] as? Double, 0.9)
    }

    func testRequestBodyCarriesOnlyTheOverrideThatIsSet() {
        let body = makeSamplingGenerator(temperature: nil, topP: 0.5)
            .requestBody(messages: [], tokenLimit: .maxTokens)

        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["top_p"] as? Double, 0.5)
    }

    func testRetryWithMaxCompletionTokensKeepsSamplingOverrides() async throws {
        final class Recorder: @unchecked Sendable { var bodies: [[String: Any]] = [] }
        let recorder = Recorder()

        MockURLProtocol.handler = { request in
            let body = self.requestBody(request)
            recorder.bodies.append(body)
            if body["max_tokens"] != nil {
                return self.mockResponse(
                    request, status: 400, body: Data(Self.unsupportedMaxTokensBody.utf8),
                )
            }
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        _ = try await makeSamplingGenerator(temperature: 0.2, topP: 0.8)
            .generate(transcript: "x", title: "t", diarized: false)

        XCTAssertEqual(recorder.bodies.count, 2)
        for body in recorder.bodies {
            XCTAssertEqual(body["temperature"] as? Double, 0.2)
            XCTAssertEqual(body["top_p"] as? Double, 0.8)
        }
    }

    func testSamplingParameterNormalizationClampsAndRounds() {
        XCTAssertEqual(OpenAISamplingParameter.temperature.normalized(2.5), 2)
        XCTAssertEqual(OpenAISamplingParameter.temperature.normalized(-1), 0)
        XCTAssertEqual(OpenAISamplingParameter.topP.normalized(1.2), 1)
        XCTAssertEqual(OpenAISamplingParameter.topP.normalized(0.1 + 0.2), 0.3)
        XCTAssertNil(OpenAISamplingParameter.temperature.normalized(.nan))
        XCTAssertNil(OpenAISamplingParameter.topP.normalized(.infinity))
    }

    func testGenerateDoesNotRetryOnUnrelated400() async throws {
        final class Recorder: @unchecked Sendable { var count = 0 }
        let recorder = Recorder()

        MockURLProtocol.handler = { request in
            recorder.count += 1
            return self.mockResponse(
                request, status: 400,
                body: Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8),
            )
        }

        let gen = makeGenerator(session: makeMockSession())
        do {
            _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
            XCTFail("expected the 400 to propagate")
        } catch let ProtocolError.httpError(status, _) {
            XCTAssertEqual(status, 400)
        }
        XCTAssertEqual(recorder.count, 1, "an unrelated 400 must not trigger a retry")
    }

    func testGenerateDoesNotRetryOnNon400NamingBothParameters() async throws {
        final class Recorder: @unchecked Sendable { var count = 0 }
        let recorder = Recorder()

        MockURLProtocol.handler = { request in
            recorder.count += 1
            return self.mockResponse(
                request, status: 502, body: Data(Self.unsupportedMaxTokensBody.utf8),
            )
        }

        let gen = makeGenerator(session: makeMockSession())
        do {
            _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
            XCTFail("expected the 502 to propagate")
        } catch let ProtocolError.httpError(status, _) {
            XCTAssertEqual(status, 502)
        }
        XCTAssertEqual(recorder.count, 1, "only an explicit 400 refusal may retry")
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

    func testGenerateTransportErrorMapsToConnectionFailed() async throws {
        // session.bytes(for:) rethrows the transport-layer URLError; generate()
        // must wrap it as ProtocolError.connectionFailed rather than leak it.
        MockURLProtocol.errorHandler = { _ in URLError(.cannotConnectToHost) }

        let gen = makeGenerator(session: makeMockSession())
        do {
            _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
            XCTFail("Expected connectionFailed")
        } catch let error as ProtocolError {
            if case let .connectionFailed(reason) = error {
                XCTAssertFalse(reason.isEmpty, "Expected a non-empty failure reason")
            } else {
                XCTFail("Expected connectionFailed, got \(error)")
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

    func testTestConnectionSetsCustomAPIKeyHeaderWithoutBearerPrefix() async {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://test.local/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret-value")
            XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return self.mockResponse(request, body: Data(#"{"data":[]}"#.utf8))
        }

        let result = await OpenAIProtocolGenerator.testConnection(
            endpoint: "http://test.local/v1/chat/completions",
            model: "test",
            apiKey: "secret-value",
            apiKeyPlacement: .customHeader,
            apiKeyHeaderName: "x-api-key",
            session: makeMockSession(),
        )
        guard case .success = result else {
            XCTFail("Expected custom-header model request to succeed, got \(result)")
            return
        }
    }

    func testTestConnectionRejectsInvalidCustomAPIKeyHeaderName() async {
        let result = await OpenAIProtocolGenerator.testConnection(
            endpoint: "http://test.local/v1",
            model: "test",
            apiKey: "secret-value",
            apiKeyPlacement: .customHeader,
            apiKeyHeaderName: "Content-Type",
            session: makeMockSession(),
        )
        guard case let .failure(error) = result else {
            XCTFail("Expected an invalid-header failure")
            return
        }
        XCTAssertTrue(error.localizedDescription.contains("Invalid API key header name"))
    }

    // MARK: - Custom API key header across redirects

    /// Redirect every request that does not already target `location` there with
    /// `status`, answer the follow-up with `body`, and record each request that
    /// reaches the answering handler.
    private func redirectOnce(status: Int, to location: String, body: String) -> OSAllocatedUnfairLock<[URLRequest]> {
        let received = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        // swiftlint:disable:next force_unwrapping
        let target = URL(string: location)!
        MockURLProtocol.redirectHandler = { request in
            request.url == target ? nil : (status, target)
        }
        MockURLProtocol.handler = { request in
            received.withLock { $0.append(request) }
            return self.mockResponse(request, body: Data(body.utf8))
        }
        return received
    }

    private func makeCustomHeaderGenerator() -> OpenAIProtocolGenerator {
        makeGenerator(
            session: makeMockSession(),
            apiKey: "secret-value",
            apiKeyPlacement: .customHeader,
            apiKeyHeaderName: "x-api-key",
        )
    }

    private func customHeaderTestConnection(
        endpoint: String = "http://test.local/v1",
    ) async -> Result<[String], any Error> {
        await OpenAIProtocolGenerator.testConnection(
            endpoint: endpoint,
            model: "test",
            apiKey: "secret-value",
            apiKeyPlacement: .customHeader,
            apiKeyHeaderName: "x-api-key",
            session: makeMockSession(),
        )
    }

    /// Run generate() and require it to fail with the redirect's own status,
    /// which is what URLSession returns once the hop is refused.
    private func assertGenerateFailsWithRedirectStatus(
        _ expected: Int, file: StaticString = #filePath, line: UInt = #line,
    ) async {
        do {
            _ = try await makeCustomHeaderGenerator().generate(transcript: "Test", title: "Test", diarized: false)
            XCTFail("Expected the refused redirect to fail the call", file: file, line: line)
        } catch let ProtocolError.httpError(status, _) {
            XCTAssertEqual(status, expected, file: file, line: line)
        } catch {
            XCTFail("Expected HTTP \(expected), got \(error)", file: file, line: line)
        }
    }

    func testGenerateRefusesRedirectToAnotherHostWithCustomAPIKeyHeader() async {
        // A 307 would replay the POST body, the whole transcript, to the new host.
        let received = redirectOnce(status: 307, to: "http://elsewhere.test/v1/chat/completions", body: Self.okSSE)

        await assertGenerateFailsWithRedirectStatus(307)

        XCTAssertEqual(received.withLock { $0 }.map(\.url), [], "nothing may reach the other host")
    }

    func testGenerateRefusesRedirectToAnotherSchemeWithCustomAPIKeyHeader() async {
        // Same host and port as the endpoint, so only the scheme differs.
        let received = redirectOnce(status: 308, to: "https://test.local:80/v1/chat/completions", body: Self.okSSE)

        await assertGenerateFailsWithRedirectStatus(308)

        XCTAssertEqual(received.withLock { $0 }.map(\.url), [], "nothing may reach the other scheme")
    }

    func testGenerateKeepsCustomAPIKeyHeaderOnSameOriginRedirect() async throws {
        let received = redirectOnce(status: 307, to: "http://test.local/v2/chat/completions", body: Self.okSSE)

        _ = try await makeCustomHeaderGenerator().generate(transcript: "Test", title: "Test", diarized: false)

        let followUp = try XCTUnwrap(received.withLock { $0 }.first)
        XCTAssertEqual(followUp.url?.path, "/v2/chat/completions")
        XCTAssertEqual(followUp.value(forHTTPHeaderField: "x-api-key"), "secret-value")
    }

    func testTestConnectionRefusesRedirectToAnotherPortWithCustomAPIKeyHeader() async {
        let received = redirectOnce(status: 302, to: "http://test.local:8080/v1/models", body: #"{"data":[]}"#)

        let result = await customHeaderTestConnection()

        guard case let .failure(error) = result else {
            XCTFail("Expected the refused redirect to fail, got \(result)")
            return
        }
        guard case let ProtocolError.httpError(status, _) = error else {
            XCTFail("Expected HTTP 302, got \(error)")
            return
        }
        XCTAssertEqual(status, 302)
        XCTAssertEqual(received.withLock { $0 }.map(\.url), [], "nothing may reach the other port")
    }

    func testTestConnectionKeepsCustomAPIKeyHeaderOnSameOriginRedirect() async throws {
        let received = redirectOnce(status: 301, to: "http://test.local/v2/models", body: #"{"data":[]}"#)

        let result = await customHeaderTestConnection()

        guard case .success = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        let followUp = try XCTUnwrap(received.withLock { $0 }.first)
        XCTAssertEqual(followUp.url?.path, "/v2/models")
        XCTAssertEqual(followUp.value(forHTTPHeaderField: "x-api-key"), "secret-value")
    }

    func testGenerateKeepsCustomAPIKeyHeaderOnRedirectToSameHostInOtherCase() async throws {
        // Host names are case-insensitive, so this hop stays on the origin.
        let received = redirectOnce(status: 307, to: "http://TEST.LOCAL/v2/chat/completions", body: Self.okSSE)

        _ = try await makeCustomHeaderGenerator().generate(transcript: "Test", title: "Test", diarized: false)

        let followUp = try XCTUnwrap(received.withLock { $0 }.first)
        XCTAssertEqual(followUp.url?.host, "TEST.LOCAL")
        XCTAssertEqual(followUp.url?.path, "/v2/chat/completions")
        XCTAssertEqual(followUp.value(forHTTPHeaderField: "x-api-key"), "secret-value")
    }

    func testTestConnectionKeepsCustomAPIKeyHeaderOnRedirectToExplicitDefaultPort() async throws {
        // An https endpoint, so the omitted port means 443 and not 80.
        let received = redirectOnce(status: 302, to: "https://test.local:443/v2/models", body: #"{"data":[]}"#)

        let result = await customHeaderTestConnection(endpoint: "https://test.local/v1")

        guard case .success = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        let followUp = try XCTUnwrap(received.withLock { $0 }.first)
        XCTAssertEqual(followUp.url?.port, 443)
        XCTAssertEqual(followUp.url?.path, "/v2/models")
        XCTAssertEqual(followUp.value(forHTTPHeaderField: "x-api-key"), "secret-value")
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

    func testTestConnectionTransportErrorMapsToConnectionFailed() async {
        // session.data(for:) rethrows the transport-layer URLError; testConnection
        // must surface it as a connectionFailed failure rather than crash/leak.
        MockURLProtocol.errorHandler = { _ in URLError(.cannotConnectToHost) }

        let result = await OpenAIProtocolGenerator.testConnection(
            endpoint: "http://test.local/v1/chat/completions",
            model: "test",
            apiKey: nil,
            session: makeMockSession(),
        )
        if case let .failure(error) = result, let pe = error as? ProtocolError, case .connectionFailed = pe {
            // expected
        } else {
            XCTFail("Expected connectionFailed failure, got \(result)")
        }
    }

    func testGenerateNonHTTPResponseThrowsConnectionFailed() async {
        // A delivered response that isn't an HTTPURLResponse must map to
        // .connectionFailed("Invalid response") — generate()'s
        // `response as? HTTPURLResponse` guard, not a crash or hang.
        MockURLProtocol.rawResponseHandler = { request in
            // swiftlint:disable:next force_unwrapping
            let response = URLResponse(url: request.url!, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
            return (response, Data())
        }

        let gen = makeGenerator(session: makeMockSession())
        do {
            _ = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
            XCTFail("Expected connectionFailed")
        } catch let error as ProtocolError {
            guard case .connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected ProtocolError.connectionFailed, got \(error)")
        }
    }

    func testTestConnectionMalformed2xxBodyReturnsEmptySuccess() async {
        // A 2xx whose JSON lacks a "data" array is a soft success with no
        // models, not a failure.
        MockURLProtocol.handler = { request in
            self.mockResponse(request, body: Data(#"{"object":"list"}"#.utf8))
        }

        let result = await OpenAIProtocolGenerator.testConnection(
            endpoint: "http://test.local/v1/chat/completions",
            model: "test",
            apiKey: nil,
            session: makeMockSession(),
        )
        if case let .success(models) = result {
            XCTAssertEqual(models, [])
        } else {
            XCTFail("Expected empty success, got \(result)")
        }
    }

    func testTestConnectionSortsModelNames() async {
        // Model ids are returned sorted regardless of the server's order.
        let modelsJSON = #"{"data":[{"id":"mistral"},{"id":"alpaca"},{"id":"llama3"}]}"#
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
            XCTAssertEqual(models, ["alpaca", "llama3", "mistral"])
        } else {
            XCTFail("Expected success, got \(result)")
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

    // MARK: - Endpoint Base-URL Handling (issue #363)

    func testTestConnectionDerivesModelsURLFromBaseURL() async {
        // Issue #363: the OpenAI ecosystem convention (and LM Studio's own UI)
        // is to enter the *base URL* ".../v1". Fetch Models must then hit
        // ".../v1/models", NOT ".../models" (which 404s on LM Studio).
        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://test.local/v1/models",
                "base URL '/v1' must resolve to '/v1/models', not '/models'",
            )
            return self.mockResponse(request, body: Data(#"{"data":[]}"#.utf8))
        }

        let result = await OpenAIProtocolGenerator.testConnection(
            endpoint: "http://test.local/v1",
            model: "test",
            apiKey: nil,
            session: makeMockSession(),
        )
        // Non-vacuity: prove the request was actually issued (handler reached),
        // so the in-handler URL assertion above is not skipped.
        guard case .success = result else {
            XCTFail("Expected the models request to be issued, got \(result)")
            return
        }
    }

    func testGeneratePostsToChatCompletionsFromBaseURL() async throws {
        // Issue #363: with the base URL ".../v1", generate() must POST to
        // ".../v1/chat/completions", not to ".../v1" itself (which 404s and
        // makes summarization fail).
        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://test.local/v1/chat/completions",
                "base URL '/v1' must POST to '/v1/chat/completions'",
            )
            return self.mockResponse(request, body: Data(Self.okSSE.utf8))
        }

        let gen = try OpenAIProtocolGenerator(
            endpoint: XCTUnwrap(URL(string: "http://test.local/v1")),
            model: "test-model",
            language: "German",
            session: makeMockSession(),
        )
        // Non-vacuity: the "OK" body is only reachable through the mock, so a
        // matching result proves the request was issued and the in-handler URL
        // assertion above actually ran.
        let result = try await gen.generate(transcript: "Test", title: "Test", diarized: false)
        XCTAssertEqual(result, "OK")
    }

    // MARK: - Full Protocol Roundtrip

    func testFullProtocolRoundtrip() async throws {
        let sseChunks = [
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"# Meeting\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\" Protocol\\n\\n\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"## Summary\\n\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Discussion about project status.\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"\\n\\n## Action Items\\n\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"- Review PR by Friday\"}}]}",
            "data: [DONE]",
        ]
        let sseBody = sseChunks.joined(separator: "\n")

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return self.mockResponse(request, body: Data(sseBody.utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        let transcript = """
        [00:00] Alice: Let's discuss the project status.
        [00:15] Bob: The PR is ready for review.
        [00:30] Alice: Please review it by Friday.
        """

        let result = try await gen.generate(
            transcript: transcript,
            title: "Sprint Planning",
            diarized: true,
        )

        XCTAssertTrue(result.contains("# Meeting Protocol"))
        XCTAssertTrue(result.contains("## Summary"))
        XCTAssertTrue(result.contains("Discussion about project status."))
        XCTAssertTrue(result.contains("## Action Items"))
        XCTAssertTrue(result.contains("Review PR by Friday"))
    }

    func testRoundtripWithSpecialCharacters() async throws {
        let sseLines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Ä Ö Ü ß\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\" — \\\"quotes\\\" & <html>\"}}]}",
            "data: [DONE]",
        ]
        let sseBody = sseLines.joined(separator: "\n")
        MockURLProtocol.handler = { request in
            self.mockResponse(request, body: Data(sseBody.utf8))
        }

        let gen = makeGenerator(session: makeMockSession())
        let result = try await gen.generate(transcript: "Test", title: "Test", diarized: false)

        XCTAssertTrue(result.contains("Ä Ö Ü ß"))
        XCTAssertTrue(result.contains("\"quotes\""))
    }
}
