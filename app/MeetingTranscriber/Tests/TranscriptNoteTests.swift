@testable import MeetingTranscriber
import XCTest

/// Putting a recording-level annotation at the top of a transcript.
///
/// The transcript is rewritten twice after it is first composed: diarization
/// replaces it with the speaker-labeled rendering, and a late re-diarization
/// rebuilds it again from the cached segments and writes it over the file. A
/// note prepended at the transcription stage is gone after either. So the note
/// lives on the job and is applied here, at each point that writes the
/// transcript out, which makes applying it twice to the same text a case this
/// has to survive rather than a case to avoid.
final class TranscriptNoteTests: XCTestCase {
    private let note = "[Recording note: the microphone track was empty.]"
    private let transcript = "Remote: good morning\nMe: morning"

    func testNoNoteLeavesTheTranscriptUntouched() {
        XCTAssertEqual(TranscriptNote.prepend(nil, to: transcript), transcript)
    }

    func testAnEmptyNoteLeavesTheTranscriptUntouched() {
        XCTAssertEqual(
            TranscriptNote.prepend("", to: transcript), transcript,
            "an empty string is a missing note, not a blank first line",
        )
    }

    func testTheNoteBecomesTheFirstLine() {
        let result = TranscriptNote.prepend(note, to: transcript)
        XCTAssertTrue(result.hasPrefix(note), "got: \(result.prefix(80))")
    }

    func testTheTranscriptSurvivesUnderTheNote() {
        let result = TranscriptNote.prepend(note, to: transcript)
        XCTAssertTrue(result.hasSuffix(transcript), "got: \(result)")
    }

    func testTheNoteIsSeparatedByABlankLine() {
        XCTAssertEqual(
            TranscriptNote.prepend(note, to: transcript),
            note + "\n\n" + transcript,
            "run together with the first utterance it reads as part of it",
        )
    }

    /// Both write sites apply the note, and the late rewrite rebuilds from
    /// cached segments whose text may already carry it. Without this the
    /// transcript grows a copy of the note on every re-diarization.
    func testApplyingTheSameNoteTwiceChangesNothing() {
        let once = TranscriptNote.prepend(note, to: transcript)
        XCTAssertEqual(TranscriptNote.prepend(note, to: once), once)
    }

    func testAnEmptyTranscriptStillGetsItsNote() {
        XCTAssertEqual(TranscriptNote.prepend(note, to: ""), note)
    }

    /// A different note replaces nothing: the case does not arise today (one
    /// note per recording) and silently dropping either one would be worse
    /// than a transcript that carries both.
    func testADifferentNoteIsAddedRatherThanSwallowed() {
        let first = TranscriptNote.prepend(note, to: transcript)
        let second = TranscriptNote.prepend("[Recording note: something else.]", to: first)
        XCTAssertTrue(second.contains(note))
        XCTAssertTrue(second.contains("[Recording note: something else.]"))
    }
}
