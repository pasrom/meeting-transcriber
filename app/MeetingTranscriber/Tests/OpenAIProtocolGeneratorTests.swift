import XCTest
@testable import MeetingTranscriber

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
        XCTAssertTrue(prompt.contains("German"))
        XCTAssertTrue(prompt.contains("Markdown"))
    }

    func testPromptIncludesDiarizationNote() {
        let note = ProtocolGenerator.diarizationNote
        XCTAssertTrue(note.contains("speaker labels"))
        XCTAssertTrue(note.contains("SPEAKER_00"))
    }

    // MARK: - Initializer

    func testDefaultTimeout() {
        let gen = OpenAIProtocolGenerator(
            endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!,
            model: "test"
        )
        XCTAssertEqual(gen.timeoutSeconds, 600)
    }

    func testCustomTimeout() {
        let gen = OpenAIProtocolGenerator(
            endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!,
            model: "test",
            timeoutSeconds: 120
        )
        XCTAssertEqual(gen.timeoutSeconds, 120)
    }

    func testAPIKeyOptional() {
        let gen = OpenAIProtocolGenerator(
            endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!,
            model: "test"
        )
        XCTAssertNil(gen.apiKey)
    }
}
