@testable import MeetingTranscriber
import XCTest

/// Unit tests for `DiarizationProcess.shiftSegments` — the pure timeline shift
/// that moves the mic track's diarization onto the app/canonical timeline by
/// `+micDelay` so it aligns with the mic transcript segments (which
/// `mergeDualSourceSegments` already shifts). Lives in its own file because
/// `DiarizationProcessTests` is already at the file-length limit.
final class DiarizationShiftSegmentsTests: XCTestCase {
    func testShiftSegments_offsetsStartAndEndPreservingMetadata() {
        let result = DiarizationResult(
            segments: [
                .init(start: 1, end: 3, speaker: "SPEAKER_0"),
                .init(start: 5, end: 8, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 2, "SPEAKER_1": 3],
            autoNames: ["SPEAKER_0": "Ann"],
            embeddings: ["SPEAKER_0": [0.1, 0.2]],
        )

        let shifted = DiarizationProcess.shiftSegments(result, by: 10)

        // Every segment moves by +offset; speaker tags unchanged.
        XCTAssertEqual(shifted.segments.map(\.start), [11, 15])
        XCTAssertEqual(shifted.segments.map(\.end), [13, 18])
        XCTAssertEqual(shifted.segments.map(\.speaker), ["SPEAKER_0", "SPEAKER_1"])
        // Timeline-independent fields pass through unchanged.
        XCTAssertEqual(shifted.speakingTimes, ["SPEAKER_0": 2, "SPEAKER_1": 3])
        XCTAssertEqual(shifted.autoNames, ["SPEAKER_0": "Ann"])
        XCTAssertEqual(shifted.embeddings?["SPEAKER_0"], [0.1, 0.2])
    }

    func testShiftSegments_negativeOffset() {
        let result = DiarizationResult(
            segments: [.init(start: 5, end: 8, speaker: "SPEAKER_0")],
            speakingTimes: [:], autoNames: [:], embeddings: nil,
        )
        let shifted = DiarizationProcess.shiftSegments(result, by: -2)
        XCTAssertEqual(shifted.segments.map(\.start), [3])
        XCTAssertEqual(shifted.segments.map(\.end), [6])
    }

    func testShiftSegments_zeroOffsetReturnsUnchanged() {
        let result = DiarizationResult(
            segments: [.init(start: 1, end: 3, speaker: "SPEAKER_0")],
            speakingTimes: [:], autoNames: [:], embeddings: nil,
        )
        let shifted = DiarizationProcess.shiftSegments(result, by: 0)
        XCTAssertEqual(shifted.segments.map(\.start), [1])
        XCTAssertEqual(shifted.segments.map(\.end), [3])
    }
}
