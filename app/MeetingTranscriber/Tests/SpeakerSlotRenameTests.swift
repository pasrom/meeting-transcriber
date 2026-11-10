@testable import MeetingTranscriber
import XCTest

final class SpeakerSlotRenameTests: XCTestCase {
    private let transcript = """
    [00:01] Alice: first
    [00:02] Bob: second
    [1:00:03] Alice: third
    """

    func testRenamesAnUnmatchedLabelAndARecognisedName() {
        let result = SpeakerSlotRename.apply(
            to: "[00:01] SPEAKER_0: hi\n[00:02] Alice: there",
            mapping: ["SPEAKER_0": "Carol", "SPEAKER_1": "Dana"],
            autoNames: ["SPEAKER_1": "Alice"],
        )
        XCTAssertEqual(result, "[00:01] Carol: hi\n[00:02] Dana: there")
    }

    /// Both speakers were recognised the wrong way round and the user swaps
    /// them. Renaming one name at a time over the whole text turns Alice into
    /// Bob and then every Bob, old and new, into Alice.
    func testSwappingTwoRecognisedNamesKeepsThemApart() {
        let result = SpeakerSlotRename.apply(
            to: transcript,
            mapping: ["SPEAKER_0": "Bob", "SPEAKER_1": "Alice"],
            autoNames: ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob"],
        )
        XCTAssertEqual(result, """
        [00:01] Bob: first
        [00:02] Alice: second
        [1:00:03] Bob: third
        """)
    }

    /// One speaker's new name is another speaker's old one.
    func testANewNameThatIsAnotherSpeakersOldNameDoesNotChain() {
        let result = SpeakerSlotRename.apply(
            to: "[00:01] Alice: first\n[00:02] SPEAKER_1: second",
            mapping: ["SPEAKER_0": "Bob", "SPEAKER_1": "Alice"],
            autoNames: ["SPEAKER_0": "Alice"],
        )
        XCTAssertEqual(result, "[00:01] Bob: first\n[00:02] Alice: second")
    }

    func testOnlyTheSpeakerSlotIsRenamed() {
        let result = SpeakerSlotRename.apply(
            to: "Note line\n[00:01] Alice: she said [aside] Alice: hello\n[00:02] no speaker here",
            mapping: ["SPEAKER_0": "Bob"],
            autoNames: ["SPEAKER_0": "Alice"],
        )
        XCTAssertEqual(result, "Note line\n[00:01] Bob: she said [aside] Alice: hello\n[00:02] no speaker here")
    }

    /// Segment text can span lines, and a continuation line can open with a
    /// bracketed tag. Only a real `[MM:SS]` or `[H:MM:SS]` stamp opens a slot,
    /// and the recording note above the transcript is bracketed too.
    func testABracketedTagThatIsNotATimestampOpensNoSlot() {
        let text = """
        [Recording note: only the app track] Alice: is not a slot
        [00:01] Alice: first
        [Music] Alice: sung, not said
        [1:00:02] Alice: later
        """
        let result = SpeakerSlotRename.apply(
            to: text,
            mapping: ["SPEAKER_0": "Bob"],
            autoNames: ["SPEAKER_0": "Alice"],
        )
        XCTAssertEqual(result, """
        [Recording note: only the app track] Alice: is not a slot
        [00:01] Bob: first
        [Music] Alice: sung, not said
        [1:00:02] Bob: later
        """)
    }

    func testAnUnchangedOrEmptyNameLeavesTheLineAlone() {
        let result = SpeakerSlotRename.apply(
            to: transcript,
            mapping: ["SPEAKER_0": "Alice", "SPEAKER_1": ""],
            autoNames: ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob"],
        )
        XCTAssertEqual(result, transcript)
    }

    /// A name may itself contain a colon-free prefix of another ("Al" and
    /// "Alice"): the slot must match whole, up to its colon.
    func testANameThatPrefixesAnotherIsNotConfused() {
        let result = SpeakerSlotRename.apply(
            to: "[00:01] Al: one\n[00:02] Alice: two",
            mapping: ["SPEAKER_0": "Xavier"],
            autoNames: ["SPEAKER_0": "Al"],
        )
        XCTAssertEqual(result, "[00:01] Xavier: one\n[00:02] Alice: two")
    }
}
