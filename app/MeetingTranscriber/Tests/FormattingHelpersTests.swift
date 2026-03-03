import Foundation
import XCTest

@testable import MeetingTranscriber

final class FormattingHelpersTests: XCTestCase {

    // MARK: - formattedTime

    func testSecondsOnly() {
        XCTAssertEqual(formattedTime(45), "45s")
    }

    func testZeroSeconds() {
        XCTAssertEqual(formattedTime(0), "0s")
    }

    func testExactMinute() {
        XCTAssertEqual(formattedTime(60), "1:00")
    }

    func testMinutesAndSeconds() {
        XCTAssertEqual(formattedTime(125), "2:05")
    }

    func testFractionalSeconds() {
        XCTAssertEqual(formattedTime(90.7), "1:30")
    }

    // MARK: - buildSpeakerMapping

    func testAllNamed() throws {
        let json = """
        [
            {"label": "SPEAKER_00", "auto_name": null, "confidence": 0.0, "speaking_time_seconds": 100.0, "sample_file": "s0.wav"},
            {"label": "SPEAKER_01", "auto_name": null, "confidence": 0.0, "speaking_time_seconds": 50.0, "sample_file": "s1.wav"}
        ]
        """.data(using: .utf8)!

        let speakers = try JSONDecoder().decode([SpeakerInfo].self, from: json)
        let mapping = buildSpeakerMapping(names: ["Roman", "Maria"], speakers: speakers)

        XCTAssertEqual(mapping.count, 2)
        XCTAssertEqual(mapping["SPEAKER_00"], "Roman")
        XCTAssertEqual(mapping["SPEAKER_01"], "Maria")
    }

    func testEmptyNamesSkipped() throws {
        let json = """
        [
            {"label": "SPEAKER_00", "auto_name": null, "confidence": 0.0, "speaking_time_seconds": 100.0, "sample_file": "s0.wav"},
            {"label": "SPEAKER_01", "auto_name": null, "confidence": 0.0, "speaking_time_seconds": 50.0, "sample_file": "s1.wav"}
        ]
        """.data(using: .utf8)!

        let speakers = try JSONDecoder().decode([SpeakerInfo].self, from: json)
        let mapping = buildSpeakerMapping(names: ["Roman", "  "], speakers: speakers)

        XCTAssertEqual(mapping.count, 1)
        XCTAssertEqual(mapping["SPEAKER_00"], "Roman")
        XCTAssertNil(mapping["SPEAKER_01"])
    }
}
