@testable import MeetingTranscriber
import XCTest

/// The system prompt a provider receives for the built-in template. The four
/// expected strings below are the prompt the code before meeting-notes
/// templates built when no custom prompt file existed, so a job using the
/// built-in template still sends exactly what it sent then.
final class ProtocolTemplateSystemPromptTests: XCTestCase {
    private static let zurich = TimeZone(identifier: "Europe/Zurich") ?? .gmt

    /// 2026-08-21 13:28 in Zurich.
    private static let meetingStart = Date(timeIntervalSince1970: 1_787_311_680)

    private static let meetingContext = """
    Meeting metadata:
    Date: 2026-08-21
    Time: 13:28
    The date and time above are authoritative. Interpret relative time expressions
    in the transcript relative to this meeting date. Do not rely on the model's
    assumed current date.


    """

    private static let diarizationNote = """

    Note: The transcript contains speaker labels in brackets. Possible label formats:
    - [SPEAKER_00], [SPEAKER_01] — auto-detected speakers (use Speaker 1, Speaker 2)
    - [Me], [Roman] etc. — the local microphone user
    - [Remote] — remote participant(s) without diarization
    - [Name] — a recognized or named speaker
    Use these labels to identify participants. In the Participants section, list them by name where possible. \
    In the Topics Discussed section, attribute key statements to speakers.
    """

    private static func builtInBody(date: String, time: String) -> String {
        """
        You are a professional meeting minute taker.
        Create a structured meeting protocol in German from the following transcript.

        Return ONLY the finished Markdown document - no explanations, no introduction,
        no comments before or after.

        Use exactly this structure:

        # Meeting Protocol - [Meeting Title]
        **Date:** \(date)
        **Time:** \(time)

        ---

        ## Summary
        [3-5 sentence summary of the meeting]

        ## Participants
        - [Name 1]
        - [Name 2]

        ## Topics Discussed

        ### [Topic 1]
        [What was discussed]

        ### [Topic 2]
        [What was discussed]

        ## Decisions
        - [Decision 1]
        - [Decision 2]

        ## Tasks
        | Task | Responsible | Deadline | Priority |
        |------|-------------|----------|----------|
        | [Description] | [Name] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

        ## Open Questions
        - [Question 1]
        - [Question 2]

        Do NOT include the full transcript in the output.

        ---
        Transcript:
        """
    }

    func testTheBuiltInTemplateSendsThePromptFromBeforeTemplates() {
        let withStart = Self.meetingContext + Self.builtInBody(date: "2026-08-21", time: "13:28")
        let withoutStart = Self.builtInBody(date: "Unknown", time: "Unknown")
        let cases: [(name: String, diarized: Bool, start: Date?, expected: String)] = [
            ("start, plain", false, Self.meetingStart, withStart),
            ("start, diarized", true, Self.meetingStart, withStart + Self.diarizationNote),
            ("no start, plain", false, nil, withoutStart),
            ("no start, diarized", true, nil, withoutStart + Self.diarizationNote),
        ]
        for testCase in cases {
            let prompt = ProtocolGenerator.buildSystemPrompt(
                diarized: testCase.diarized,
                language: "German",
                meetingStartTime: testCase.start,
                instructions: ProtocolInstructions(template: ProtocolGenerator.protocolPrompt),
                timeZone: Self.zurich,
            )
            XCTAssertEqual(prompt, testCase.expected, testCase.name)
        }
    }

    /// A template of the user's own takes the built-in one's place, with the
    /// same placeholders filled in and the same meeting context before it.
    func testAUserTemplateReplacesTheBuiltInAndHasItsPlaceholdersFilled() {
        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false, language: "German", meetingStartTime: Self.meetingStart,
            instructions: ProtocolInstructions(template: "Board notes in {LANGUAGE} for {MEETING_DATE} at {MEETING_TIME}."),
            timeZone: Self.zurich,
        )

        XCTAssertEqual(prompt, Self.meetingContext + "Board notes in German for 2026-08-21 at 13:28.")
    }
}
