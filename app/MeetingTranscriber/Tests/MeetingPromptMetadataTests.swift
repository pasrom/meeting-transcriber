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
}
