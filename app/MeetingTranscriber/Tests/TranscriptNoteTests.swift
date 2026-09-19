@testable import MeetingTranscriber
import XCTest

/// Putting a recording-level annotation at the top of a transcript.
///
/// Reached from one place, the rendering every transcript that lands on disk
/// goes through, so what is pinned here is the composition itself: what counts
/// as no note, where the note sits, and that the transcript underneath it comes
/// through untouched.
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

    func testAnEmptyTranscriptStillGetsItsNote() {
        XCTAssertEqual(TranscriptNote.prepend(note, to: ""), note)
    }
}
