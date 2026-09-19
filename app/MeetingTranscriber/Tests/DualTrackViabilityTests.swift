@testable import MeetingTranscriber
import XCTest

/// Which tracks of a dual-source recording are worth handing to the ASR engine.
///
/// The field cases this exists for all look the same on disk: a `_mic.wav` of
/// 4096 bytes holding a WAV header and zero audio packets, next to an app track
/// with ten minutes of the far end. Transcribing the empty one threw
/// `Invalid audio data provided. Must be at least 300ms of 16kHz audio` out of
/// the whole job and discarded the good track with it (issue #724).
///
/// The decision is taken on track length rather than by catching that error,
/// because the error belongs to one engine: the same empty file reaches
/// WhisperKit too, and a `try?` around the call would also swallow a model that
/// failed to load or a cancelled job. A length is engine-independent and can be
/// pinned here without audio, an engine, or a machine with a microphone.
final class DualTrackViabilityTests: XCTestCase {
    /// 300 ms at 16 kHz, FluidAudio's own guard (`ASRConstants`).
    private let minimum = 4800

    // MARK: - The four arms

    func testBothTracksSurviveWhenEachCarriesEnoughAudio() {
        XCTAssertEqual(
            DualTrackViability.resolve(appFrames: 160_000, micFrames: 160_000, minimumFrames: minimum),
            .both,
        )
    }

    /// The field cases are header-only files rather than zero-byte ones, and
    /// both reduce to the same frame count. That is why the check is on frames
    /// and not on the file size the recorder already gates on: 4096 bytes pass
    /// `> 44` and did.
    func testAnEmptyMicTrackLeavesTheAppTrack() {
        XCTAssertEqual(
            DualTrackViability.resolve(appFrames: 10_208_000, micFrames: 0, minimumFrames: minimum),
            .appOnly,
            "the recording that cost 10 minutes: 638 s of far end next to a 0-packet mic file",
        )
    }

    func testAnEmptyAppTrackLeavesTheMicTrack() {
        XCTAssertEqual(
            DualTrackViability.resolve(appFrames: 0, micFrames: 160_000, minimumFrames: minimum),
            .micOnly,
        )
    }

    func testBothEmptyIsTheOnlyCaseThatFailsTheJob() {
        XCTAssertEqual(
            DualTrackViability.resolve(appFrames: 0, micFrames: 0, minimumFrames: minimum),
            .neither,
        )
    }

    // MARK: - The boundary is the engine's own guard

    func testATrackExactlyAtTheMinimumIsKept() {
        XCTAssertEqual(
            DualTrackViability.resolve(appFrames: 160_000, micFrames: minimum, minimumFrames: minimum),
            .both,
            "the engine accepts 300 ms, so the guard must not reject what the engine would take",
        )
    }

    func testATrackOneFrameShortOfTheMinimumIsDropped() {
        XCTAssertEqual(
            DualTrackViability.resolve(appFrames: 160_000, micFrames: minimum - 1, minimumFrames: minimum),
            .appOnly,
            "one frame below the engine's guard is what throws, so it has to be caught here",
        )
    }

    // MARK: - Which track a stage may still touch

    func testBothTracksAreOfferedWhenBothCarryAudio() {
        XCTAssertTrue(DualTrackViability.both.carriesAppAudio)
        XCTAssertTrue(DualTrackViability.both.carriesMicAudio)
    }

    /// The reason these exist: a stage downstream of transcription must not
    /// hand a file already measured as empty to a model.
    func testADroppedTrackIsNotOfferedToALaterStage() {
        XCTAssertTrue(DualTrackViability.appOnly.carriesAppAudio)
        XCTAssertFalse(DualTrackViability.appOnly.carriesMicAudio)
        XCTAssertFalse(DualTrackViability.micOnly.carriesAppAudio)
        XCTAssertTrue(DualTrackViability.micOnly.carriesMicAudio)
    }

    func testNeitherTrackIsOfferedWhenBothAreEmpty() {
        XCTAssertFalse(DualTrackViability.neither.carriesAppAudio)
        XCTAssertFalse(DualTrackViability.neither.carriesMicAudio)
    }

    // MARK: - What the user is told

    func testOnlyTheDroppedArmsCarryAWarning() {
        XCTAssertNil(DualTrackViability.both.droppedTrackWarning)
        XCTAssertNil(
            DualTrackViability.neither.droppedTrackWarning,
            "a job that fails reports the failure, not a warning nobody will read",
        )
        XCTAssertNotNil(DualTrackViability.appOnly.droppedTrackWarning)
        XCTAssertNotNil(DualTrackViability.micOnly.droppedTrackWarning)
    }

    func testTheWarningNamesTheTrackThatWasDropped() throws {
        let appOnly = try XCTUnwrap(DualTrackViability.appOnly.droppedTrackWarning)
        XCTAssertTrue(appOnly.lowercased().contains("microphone"), "got: \(appOnly)")
        let micOnly = try XCTUnwrap(DualTrackViability.micOnly.droppedTrackWarning)
        XCTAssertTrue(micOnly.lowercased().contains("app"), "got: \(micOnly)")
    }

    // MARK: - What the transcript says

    func testOnlyTheDroppedArmsCarryATranscriptNote() {
        XCTAssertNil(DualTrackViability.both.transcriptNote)
        XCTAssertNil(DualTrackViability.neither.transcriptNote)
        XCTAssertNotNil(DualTrackViability.appOnly.transcriptNote)
        XCTAssertNotNil(DualTrackViability.micOnly.transcriptNote)
    }

    /// The note is read by the protocol model as well as by a person, so it has
    /// to say what is missing without being mistakable for something a
    /// participant said. A bracketed prefix is the whole mechanism: the prompt
    /// cannot be relied on to explain it, because a user-supplied
    /// `protocol_prompt.md` replaces the built-in one.
    func testTheNoteIsMarkedAsAnAnnotationRatherThanSpeech() throws {
        for viability in [DualTrackViability.appOnly, .micOnly] {
            let note = try XCTUnwrap(viability.transcriptNote)
            XCTAssertTrue(note.hasPrefix("["), "got: \(note)")
            XCTAssertTrue(note.hasSuffix("]"), "got: \(note)")
            XCTAssertFalse(note.contains("\n"), "a single line, so it cannot look like a block of speech")
        }
    }

    func testTheNoteSaysWhichSideOfTheConversationIsMissing() throws {
        let appOnly = try XCTUnwrap(DualTrackViability.appOnly.transcriptNote)
        XCTAssertTrue(appOnly.lowercased().contains("microphone"), "got: \(appOnly)")
        let micOnly = try XCTUnwrap(DualTrackViability.micOnly.transcriptNote)
        XCTAssertTrue(micOnly.lowercased().contains("app"), "got: \(micOnly)")
    }
}
