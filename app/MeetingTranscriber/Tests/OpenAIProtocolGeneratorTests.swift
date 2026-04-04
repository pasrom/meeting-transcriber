@testable import MeetingTranscriber
import XCTest

final class OpenAIProtocolGeneratorTests: XCTestCase {
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
}
