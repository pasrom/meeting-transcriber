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

    func testBuildSystemPromptWithoutMeetingStartDoesNotAddAuthority() {
        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false,
            language: "German",
            meetingStartTime: nil,
            instructions: ProtocolInstructions(template: "Date: {MEETING_DATE}; Time: {MEETING_TIME}."),
        )

        XCTAssertEqual(prompt, "Date: Unknown; Time: Unknown.")
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("authoritative"))
    }
}
