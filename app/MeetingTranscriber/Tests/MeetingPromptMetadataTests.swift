@testable import MeetingTranscriber
import XCTest

final class MeetingPromptMetadataTests: XCTestCase {
    func testApplyVariablesUsesUnknownForMissingMeetingStart() {
        let result = ProtocolGenerator.applyVariables(
            "{LANGUAGE} {MEETING_DATE} {MEETING_TIME}",
            language: "German",
            metadata: nil,
        )

        XCTAssertEqual(result, "German Unknown Unknown")
    }

    func testBuildSystemPromptWithoutMeetingStartDoesNotAddAuthority() throws {
        let url = makeTempFile(suffix: ".md")
        try "Date: {MEETING_DATE}; Time: {MEETING_TIME}.".write(to: url, atomically: true, encoding: .utf8)

        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false,
            language: "German",
            meetingStartTime: nil,
            promptURL: url,
        )

        XCTAssertEqual(prompt, "Date: Unknown; Time: Unknown.")
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("authoritative"))
    }

    // MARK: - Meeting title in the prompt

    func testPromptTitleKeepsOnlyTheSubjectOfAWindowTitle() {
        XCTAssertEqual(
            ProtocolGenerator.promptTitle(from: "acme budget review | Acme Corp | user@example.com"),
            "acme budget review",
        )
    }

    func testPromptTitleDropsGenericTitlesAndFileStems() {
        for generic in [
            "Rejoindre la réunion | Réunion Microsoft Teams", "Join meeting", "New Recording 1", "WhatsApp Call",
            "30 Min Meeting", "  ", "", "20250101_0900_acme_budget_review_ab12cd34",
        ] {
            XCTAssertNil(ProtocolGenerator.promptTitle(from: generic), generic)
        }
        XCTAssertNil(ProtocolGenerator.promptTitle(from: nil))
    }

    func testBuildSystemPromptCarriesTheTitleInTheMetadataBlock() throws {
        let url = makeTempFile(suffix: ".md")
        try "BODY".write(to: url, atomically: true, encoding: .utf8)

        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false,
            language: "French",
            meetingStartTime: Date(timeIntervalSince1970: 0),
            title: "acme budget review | Acme Corp | user@example.com",
            promptURL: url,
            timeZone: TimeZone(identifier: "UTC")!,
        )

        XCTAssertTrue(prompt.hasPrefix("Meeting metadata:\nDate: 1970-01-01\nTime: 00:00\nTitle: acme budget review\n"))
        XCTAssertFalse(prompt.contains("user@example.com"))
        XCTAssertTrue(prompt.hasSuffix("BODY"))
    }

    func testBuildSystemPromptWithGenericTitleIsUnchanged() throws {
        let url = makeTempFile(suffix: ".md")
        try "BODY".write(to: url, atomically: true, encoding: .utf8)

        let withTitle = ProtocolGenerator.buildSystemPrompt(
            diarized: false, language: "French", meetingStartTime: nil, title: "New Recording 1", promptURL: url,
        )
        let without = ProtocolGenerator.buildSystemPrompt(
            diarized: false, language: "French", meetingStartTime: nil, promptURL: url,
        )

        XCTAssertEqual(withTitle, without)
        XCTAssertEqual(without, "BODY")
    }
}
