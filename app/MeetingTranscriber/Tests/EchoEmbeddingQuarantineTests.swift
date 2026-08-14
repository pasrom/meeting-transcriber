@testable import MeetingTranscriber
import XCTest

/// The quarantine is what stops an echo-affected recording from permanently
/// poisoning the speaker database, so these tests care as much about what stays
/// admissible as about what is held back: a filter that drops everything would
/// satisfy the safety half alone and quietly stop the app learning voices.
final class EchoEmbeddingQuarantineTests: XCTestCase {
    private let remote = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
    private let localVoice = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded

    private func dualTrackEmbeddings() -> [String: [Float]] {
        [remote: [1, 0, 0], localVoice: [0, 1, 0]]
    }

    func testUnmeasuredRecordingIsUntouched() {
        let input = dualTrackEmbeddings()
        let out = EchoEmbeddingQuarantine.admissible(input, verdict: .notMeasured, isDualSource: true)
        XCTAssertEqual(
            out.keys.sorted(),
            input.keys.sorted(),
            "A recording the detector never measured must behave exactly as before the quarantine existed",
        )
    }

    func testCleanRecordingIsUntouched() {
        let input = dualTrackEmbeddings()
        let out = EchoEmbeddingQuarantine.admissible(input, verdict: .clean, isDualSource: true)
        XCTAssertEqual(out.keys.sorted(), input.keys.sorted())
    }

    func testAffectedRecordingHoldsBackTheMicrophoneTrack() {
        let out = EchoEmbeddingQuarantine.admissible(
            dualTrackEmbeddings(), verdict: .affected, isDualSource: true,
        )
        XCTAssertNil(out[localVoice], "The microphone track carries the bled-in voice; its embedding must not reach the DB")
    }

    func testAffectedRecordingStillAdmitsTheAppTrack() {
        let out = EchoEmbeddingQuarantine.admissible(
            dualTrackEmbeddings(), verdict: .affected, isDualSource: true,
        )
        XCTAssertEqual(
            out[remote],
            [1, 0, 0],
            "The bleed travels loudspeaker → microphone, so the app track is not contaminated and a remote participant is still learned",
        )
    }

    /// The single-track fallback: one track's diarization failed, so the merge
    /// never ran and the surviving labels carry no prefix. Which track survived
    /// is not recoverable, and one of the two candidates is entirely
    /// contaminated.
    func testAffectedDualSourceWithNoTrackPrefixesHoldsBackEverything() {
        let unprefixed = [
            "SPEAKER_0": [Float](repeating: 1, count: 3),
            "SPEAKER_1": [Float](repeating: 2, count: 3),
        ]
        let out = EchoEmbeddingQuarantine.admissible(unprefixed, verdict: .affected, isDualSource: true)
        XCTAssertTrue(
            out.isEmpty,
            "With the track unknowable on a recording known to be affected, holding everything is the only safe answer",
        )
    }

    /// A single-source recording has no microphone track to quarantine, and the
    /// detector never runs on one — but the filter must be total, and a stray
    /// true here must not silently stop enrollment.
    func testSingleSourceRecordingIsUntouchedEvenIfFlagged() {
        let single = ["SPEAKER_0": [Float](repeating: 1, count: 3)]
        let out = EchoEmbeddingQuarantine.admissible(single, verdict: .affected, isDualSource: false)
        XCTAssertEqual(out.keys.sorted(), single.keys.sorted())
    }

    func testEmptyInputStaysEmptyWithoutCrashing() {
        XCTAssertTrue(EchoEmbeddingQuarantine.admissible([:], verdict: .affected, isDualSource: true).isEmpty)
        XCTAssertTrue(EchoEmbeddingQuarantine.admissible([:], verdict: .clean, isDualSource: true).isEmpty)
    }
}
