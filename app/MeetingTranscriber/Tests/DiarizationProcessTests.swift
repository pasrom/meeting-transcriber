import XCTest

@testable import MeetingTranscriber

final class DiarizationProcessTests: XCTestCase {

    // MARK: - Speaker Assignment

    func testAssignSpeakers() {
        let transcript = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
            TimestampedSegment(start: 5, end: 10, text: "World"),
            TimestampedSegment(start: 10, end: 15, text: "Bye"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 6, speaker: "Alice"),
                .init(start: 6, end: 15, speaker: "Bob"),
            ],
            speakingTimes: ["Alice": 6, "Bob": 9],
            autoNames: [:],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        XCTAssertEqual(result[0].speaker, "Alice")  // 0-5 overlaps Alice (0-6)
        XCTAssertEqual(result[1].speaker, "Bob")     // 5-10: 1s Alice, 4s Bob -> Bob
        XCTAssertEqual(result[2].speaker, "Bob")     // 10-15 fully Bob
    }

    func testAssignSpeakersNoOverlap() {
        let transcript = [
            TimestampedSegment(start: 100, end: 105, text: "Late"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "Alice"),
            ],
            speakingTimes: ["Alice": 5],
            autoNames: [:],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        XCTAssertEqual(result[0].speaker, "UNKNOWN")
    }

    func testAssignSpeakersEmpty() {
        let result = DiarizationProcess.assignSpeakers(
            transcript: [],
            diarization: DiarizationResult(segments: [], speakingTimes: [:], autoNames: [:], embeddings: nil)
        )
        XCTAssertTrue(result.isEmpty)
    }
}
