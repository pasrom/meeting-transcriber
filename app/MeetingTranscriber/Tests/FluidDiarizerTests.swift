@testable import MeetingTranscriber
import XCTest

final class FluidDiarizerTests: XCTestCase {
    func testIsAlwaysAvailable() {
        let diarizer = FluidDiarizer()
        XCTAssertTrue(diarizer.isAvailable)
    }

    // MARK: - normalizeSpeakerId

    func testNormalizeSpeakerIdStandard() {
        XCTAssertEqual(FluidDiarizer.normalizeSpeakerId("Speaker 0"), "SPEAKER_0")
    }

    func testNormalizeSpeakerIdMultipleDigits() {
        XCTAssertEqual(FluidDiarizer.normalizeSpeakerId("Speaker 12"), "SPEAKER_12")
    }

    func testNormalizeSpeakerIdAlreadyNormalized() {
        XCTAssertEqual(FluidDiarizer.normalizeSpeakerId("SPEAKER_0"), "SPEAKER_0")
    }

    func testNormalizeSpeakerIdNoMatch() {
        XCTAssertEqual(FluidDiarizer.normalizeSpeakerId("Custom Name"), "Custom Name")
    }

    // MARK: - buildResult

    func testBuildResultSortsByStartTime() {
        let diarizer = FluidDiarizer()
        let segments: [DiarizationResult.Segment] = [
            .init(start: 5, end: 10, speaker: "SPEAKER_0"),
            .init(start: 0, end: 5, speaker: "SPEAKER_1"),
        ]
        let result = diarizer.buildResult(segments: segments, speakerDatabase: nil)
        XCTAssertEqual(result.segments[0].start, 0)
        XCTAssertEqual(result.segments[1].start, 5)
    }

    func testBuildResultComputesSpeakingTimes() {
        let diarizer = FluidDiarizer()
        let segments: [DiarizationResult.Segment] = [
            .init(start: 0, end: 5, speaker: "SPEAKER_0"),
            .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            .init(start: 10, end: 20, speaker: "SPEAKER_0"),
        ]
        let result = diarizer.buildResult(segments: segments, speakerDatabase: nil)
        XCTAssertEqual(result.speakingTimes["SPEAKER_0"], 15.0)
        XCTAssertEqual(result.speakingTimes["SPEAKER_1"], 5.0)
    }

    func testBuildResultEmptySegments() {
        let diarizer = FluidDiarizer()
        let result = diarizer.buildResult(segments: [], speakerDatabase: nil)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakingTimes.isEmpty)
    }

    func testBuildResultNilEmbeddings() {
        let diarizer = FluidDiarizer()
        let result = diarizer.buildResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakerDatabase: nil,
        )
        XCTAssertNil(result.embeddings)
    }
}
