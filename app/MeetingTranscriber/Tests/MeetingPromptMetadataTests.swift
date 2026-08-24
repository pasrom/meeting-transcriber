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

        // Guidance about the unknown start is fine; an authority claim is not.
        // Equality pins that the placeholders stay a short scalar (custom
        // prompts may embed them in front matter or table cells) and that the
        // guidance scopes any transcript-stated date to this meeting itself.
        XCTAssertEqual(
            prompt,
            """
            No reliable meeting start time was captured for this recording.
            If the transcript states when this meeting itself took place, use that
            date and time; otherwise leave them as Unknown. Never substitute the
            current date or the processing time.

            Date: Unknown; Time: Unknown.
            """,
        )
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("authoritative"))
    }

    func testBuiltInTemplateHeaderResolvesToUnknownWithGuidance() {
        // The prompt file is never created, so loadPrompt falls back to the
        // built-in default template, the one whose reproduced header showed
        // the defect. The other tests inject their own template, which leaves
        // the shipped header unasserted.
        let url = makeTempFile(suffix: ".md")
        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false,
            language: "German",
            meetingStartTime: nil,
            promptURL: url,
        )

        XCTAssertTrue(prompt.contains("**Date:** Unknown"))
        XCTAssertTrue(prompt.contains("**Time:** Unknown"))
        XCTAssertTrue(prompt.contains("No reliable meeting start time was captured"))
    }

    func testPromptWithoutMeetingStartNeverMentionsToday() {
        // Invariant, deliberately looser than string equality: no rewording
        // of the guidance or the built-in template may quietly reintroduce
        // "or today", because presenting the processing day as the meeting
        // day was the defect the captured-start feature fixed.
        let url = makeTempFile(suffix: ".md")
        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false,
            language: "German",
            meetingStartTime: nil,
            promptURL: url,
        )

        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("today"))
    }
}
