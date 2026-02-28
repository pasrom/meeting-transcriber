import Foundation
import XCTest

@testable import MeetingTranscriber

final class SpeakerIPCTests: XCTestCase {

    // MARK: - Decode SpeakerRequest

    func testDecodeSpeakerRequest() throws {
        let json = """
        {
            "version": 1,
            "timestamp": "2026-02-28T14:30:00",
            "meeting_title": "Sprint Planning",
            "audio_samples_dir": "/tmp/samples",
            "speakers": [
                {
                    "label": "SPEAKER_00",
                    "auto_name": "Roman",
                    "confidence": 0.87,
                    "speaking_time_seconds": 120.5,
                    "sample_file": "SPEAKER_00.wav"
                },
                {
                    "label": "SPEAKER_01",
                    "auto_name": null,
                    "confidence": 0.0,
                    "speaking_time_seconds": 45.2,
                    "sample_file": "SPEAKER_01.wav"
                }
            ]
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(SpeakerRequest.self, from: json)

        XCTAssertEqual(request.version, 1)
        XCTAssertEqual(request.timestamp, "2026-02-28T14:30:00")
        XCTAssertEqual(request.meetingTitle, "Sprint Planning")
        XCTAssertEqual(request.audioSamplesDir, "/tmp/samples")
        XCTAssertEqual(request.speakers.count, 2)
        XCTAssertEqual(request.speakers[0].label, "SPEAKER_00")
        XCTAssertEqual(request.speakers[0].autoName, "Roman")
        XCTAssertEqual(request.speakers[1].autoName, nil)
    }

    // MARK: - Snake-case key mapping

    func testDecodeSpeakerRequestSnakeCaseKeys() throws {
        let json = """
        {
            "version": 1,
            "timestamp": "2026-02-28T14:30:00",
            "meeting_title": "Daily",
            "audio_samples_dir": "/home/user/.meeting-transcriber/speaker_samples",
            "speakers": [
                {
                    "label": "SPEAKER_00",
                    "auto_name": "Maria",
                    "confidence": 0.92,
                    "speaking_time_seconds": 200.0,
                    "sample_file": "SPEAKER_00.wav"
                }
            ]
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(SpeakerRequest.self, from: json)

        // Verify snake_case → camelCase mapping via CodingKeys
        XCTAssertEqual(request.meetingTitle, "Daily")
        XCTAssertEqual(request.audioSamplesDir, "/home/user/.meeting-transcriber/speaker_samples")

        let speaker = request.speakers[0]
        XCTAssertEqual(speaker.autoName, "Maria")
        XCTAssertEqual(speaker.speakingTimeSeconds, 200.0)
        XCTAssertEqual(speaker.sampleFile, "SPEAKER_00.wav")
    }

    // MARK: - Encode SpeakerResponse

    func testEncodeSpeakerResponse() throws {
        let response = SpeakerResponse(
            version: 1,
            speakers: ["SPEAKER_00": "Roman", "SPEAKER_01": "Maria"]
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(decoded["version"] as? Int, 1)

        let speakers = decoded["speakers"] as! [String: String]
        XCTAssertEqual(speakers["SPEAKER_00"], "Roman")
        XCTAssertEqual(speakers["SPEAKER_01"], "Maria")
    }

    // MARK: - Decode TranscriberStatus with waiting state

    func testDecodeTranscriberStatusWaitingState() throws {
        let json = """
        {
            "version": 1,
            "timestamp": "2026-02-28T14:30:00",
            "state": "waiting_for_speaker_names",
            "detail": "2 speakers detected",
            "meeting": null,
            "protocol_path": null,
            "error": null,
            "pid": 12345
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(TranscriberStatus.self, from: json)

        XCTAssertEqual(status.state, .waitingForSpeakerNames)
        XCTAssertEqual(status.detail, "2 speakers detected")
        XCTAssertEqual(status.pid, 12345)
    }
}
