import XCTest

@testable import MeetingTranscriber

final class DiarizationProcessTests: XCTestCase {

    // MARK: - JSON Parsing

    func testParseValidOutput() throws {
        let json = """
            {
              "segments": [
                {"start": 0.0, "end": 5.2, "speaker": "SPEAKER_00"},
                {"start": 5.2, "end": 10.1, "speaker": "SPEAKER_01"},
                {"start": 10.1, "end": 15.0, "speaker": "SPEAKER_00"}
              ],
              "embeddings": {
                "SPEAKER_00": [0.1, 0.2, 0.3],
                "SPEAKER_01": [0.4, 0.5, 0.6]
              },
              "auto_names": {
                "SPEAKER_00": "Alice"
              },
              "speaking_times": {
                "SPEAKER_00": 10.1,
                "SPEAKER_01": 4.9
              }
            }
            """
        let data = Data(json.utf8)
        let result = try DiarizationProcess.parseOutput(data)

        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result.segments[0].start, 0.0)
        XCTAssertEqual(result.segments[0].end, 5.2)
        XCTAssertEqual(result.segments[1].speaker, "SPEAKER_01")

        XCTAssertEqual(result.speakingTimes["SPEAKER_00"], 10.1)
        XCTAssertEqual(result.speakingTimes["SPEAKER_01"], 4.9)

        XCTAssertEqual(result.autoNames["SPEAKER_00"], "Alice")
        XCTAssertNil(result.autoNames["SPEAKER_01"])
    }

    func testParseEmptySegments() throws {
        let json = """
            {"segments": [], "embeddings": {}, "auto_names": {}, "speaking_times": {}}
            """
        let result = try DiarizationProcess.parseOutput(Data(json.utf8))
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakingTimes.isEmpty)
    }

    func testParseInvalidJSON() {
        let data = Data("not json".utf8)
        XCTAssertThrowsError(try DiarizationProcess.parseOutput(data))
    }

    func testParseMissingFields() throws {
        // segments with missing fields should be skipped
        let json = """
            {"segments": [{"start": 0.0}, {"start": 1.0, "end": 2.0, "speaker": "A"}]}
            """
        let result = try DiarizationProcess.parseOutput(Data(json.utf8))
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].speaker, "A")
    }

    // MARK: - Availability

    func testNotAvailableByDefault() {
        let proc = DiarizationProcess(
            pythonPath: URL(fileURLWithPath: "/nonexistent/python"),
            scriptPath: URL(fileURLWithPath: "/nonexistent/diarize.py")
        )
        XCTAssertFalse(proc.isAvailable)
    }

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
            autoNames: [:]
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        XCTAssertEqual(result[0].speaker, "Alice")  // 0-5 overlaps Alice (0-6)
        XCTAssertEqual(result[1].speaker, "Bob")     // 5-10: 1s Alice, 4s Bob → Bob
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
            autoNames: [:]
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        XCTAssertEqual(result[0].speaker, "UNKNOWN")
    }

    func testAssignSpeakersEmpty() {
        let result = DiarizationProcess.assignSpeakers(
            transcript: [],
            diarization: DiarizationResult(segments: [], speakingTimes: [:], autoNames: [:])
        )
        XCTAssertTrue(result.isEmpty)
    }
}
