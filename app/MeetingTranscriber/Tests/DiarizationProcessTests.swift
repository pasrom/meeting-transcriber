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

        // Nearest fallback: Alice is the only (and nearest) speaker
        XCTAssertEqual(result[0].speaker, "Alice")
    }

    func testAssignSpeakersUsesAutoNames() {
        let transcript = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
            TimestampedSegment(start: 5, end: 10, text: "World"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 6, speaker: "SPEAKER_0"),
                .init(start: 6, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 6, "SPEAKER_1": 4],
            autoNames: ["SPEAKER_0": "Roman", "SPEAKER_1": "Anna"],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        XCTAssertEqual(result[0].speaker, "Roman")
        XCTAssertEqual(result[1].speaker, "Anna")
    }

    func testAssignSpeakersEmpty() {
        let result = DiarizationProcess.assignSpeakers(
            transcript: [],
            diarization: DiarizationResult(segments: [], speakingTimes: [:], autoNames: [:], embeddings: nil)
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Nearest Fallback

    func testAssignSpeakersNearestFallback() {
        // Segment in a gap between two diarization speakers — should pick the nearest
        let transcript = [
            TimestampedSegment(start: 12, end: 14, text: "In the gap"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 15, end: 20, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            autoNames: ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob"],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        // Gap to SPEAKER_1 is 15-14=1s, gap to SPEAKER_0 is 12-5=7s → nearest is Bob
        XCTAssertEqual(result[0].speaker, "Bob")
    }

    func testAssignSpeakersNoDiarizationSegments() {
        let transcript = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]

        let diarization = DiarizationResult(
            segments: [],
            speakingTimes: [:],
            autoNames: [:],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        // No diarization segments at all → UNKNOWN
        XCTAssertEqual(result[0].speaker, "UNKNOWN")
    }

    // MARK: - Identify Mic Speaker

    func testIdentifyMicSpeaker_findsCorrectSpeaker() {
        let micSegments = [
            TimestampedSegment(start: 0, end: 10, text: "I'm speaking"),
            TimestampedSegment(start: 20, end: 30, text: "Still me"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 12, speaker: "SPEAKER_0"),
                .init(start: 12, end: 20, speaker: "SPEAKER_1"),
                .init(start: 20, end: 30, speaker: "SPEAKER_0"),
            ],
            speakingTimes: ["SPEAKER_0": 22, "SPEAKER_1": 8],
            autoNames: [:],
            embeddings: nil
        )

        let result = DiarizationProcess.identifyMicSpeaker(
            micSegments: micSegments, diarization: diarization
        )

        // Mic total = 20s. SPEAKER_0 overlap: 10s (0-10) + 10s (20-30) = 20s. Ratio = 1.0
        XCTAssertEqual(result, "SPEAKER_0")
    }

    func testIdentifyMicSpeaker_belowThreshold() {
        let micSegments = [
            TimestampedSegment(start: 0, end: 10, text: "Short overlap"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 8, end: 12, speaker: "SPEAKER_0"),
            ],
            speakingTimes: ["SPEAKER_0": 4],
            autoNames: [:],
            embeddings: nil
        )

        // Overlap = 2s (8-10), total mic = 10s, ratio = 0.2 < 0.3 threshold
        let result = DiarizationProcess.identifyMicSpeaker(
            micSegments: micSegments, diarization: diarization
        )

        XCTAssertNil(result)
    }

    func testIdentifyMicSpeaker_emptyMicSegments() {
        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
            ],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: nil
        )

        let result = DiarizationProcess.identifyMicSpeaker(
            micSegments: [], diarization: diarization
        )

        XCTAssertNil(result)
    }

    // MARK: - Hybrid Speaker Assignment

    func testAssignSpeakersHybrid_micKeepsLabel() {
        let micSegments = [
            TimestampedSegment(start: 0, end: 5, text: "Hello from mic"),
            TimestampedSegment(start: 10, end: 15, text: "More from mic"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            autoNames: ["SPEAKER_0": "Roman", "SPEAKER_1": "Anna"],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakersHybrid(
            appSegments: [],
            micSegments: micSegments,
            diarization: diarization,
            micSpeakerID: "SPEAKER_0",
            micLabel: "Me"
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Me")
        XCTAssertEqual(result[1].speaker, "Me")
    }

    func testAssignSpeakersHybrid_appGetsRemoteSpeakers() {
        let appSegments = [
            TimestampedSegment(start: 5, end: 10, text: "Remote person A"),
            TimestampedSegment(start: 15, end: 20, text: "Remote person B"),
        ]

        let micSegments = [
            TimestampedSegment(start: 0, end: 5, text: "Me talking"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),   // mic speaker
                .init(start: 5, end: 12, speaker: "SPEAKER_1"),  // remote A
                .init(start: 12, end: 20, speaker: "SPEAKER_2"), // remote B
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 7, "SPEAKER_2": 8],
            autoNames: ["SPEAKER_0": "Roman", "SPEAKER_1": "Anna", "SPEAKER_2": "Max"],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakersHybrid(
            appSegments: appSegments,
            micSegments: micSegments,
            diarization: diarization,
            micSpeakerID: "SPEAKER_0",
            micLabel: "Me"
        )

        // Should be sorted by start time: mic(0-5), app(5-10), app(15-20)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].speaker, "Me")    // mic
        XCTAssertEqual(result[1].speaker, "Anna")  // app overlaps SPEAKER_1, mic speaker excluded
        XCTAssertEqual(result[2].speaker, "Max")   // app overlaps SPEAKER_2, mic speaker excluded
    }

    // MARK: - Dual-Track Diarization

    func testMergeDualTrackDiarization() {
        let appDiarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0], "SPEAKER_1": [0, 1]]
        )

        let micDiarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 8, speaker: "SPEAKER_0"),
            ],
            speakingTimes: ["SPEAKER_0": 8],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [0.5, 0.5]]
        )

        let merged = DiarizationProcess.mergeDualTrackDiarization(
            appDiarization: appDiarization,
            micDiarization: micDiarization
        )

        // App speakers prefixed with R_, mic with M_
        XCTAssertEqual(merged.segments.count, 3)
        let speakers = Set(merged.segments.map { $0.speaker })
        XCTAssertTrue(speakers.contains("R_SPEAKER_0"))
        XCTAssertTrue(speakers.contains("R_SPEAKER_1"))
        XCTAssertTrue(speakers.contains("M_SPEAKER_0"))

        // Speaking times prefixed
        XCTAssertEqual(merged.speakingTimes["R_SPEAKER_0"], 5)
        XCTAssertEqual(merged.speakingTimes["R_SPEAKER_1"], 5)
        XCTAssertEqual(merged.speakingTimes["M_SPEAKER_0"], 8)

        // Embeddings prefixed
        XCTAssertEqual(merged.embeddings?["R_SPEAKER_0"], [1, 0])
        XCTAssertEqual(merged.embeddings?["R_SPEAKER_1"], [0, 1])
        XCTAssertEqual(merged.embeddings?["M_SPEAKER_0"], [0.5, 0.5])

        // Segments sorted by start time
        XCTAssertEqual(merged.segments[0].start, 0)
        XCTAssertEqual(merged.segments[1].start, 0)
        // Both start at 0 — order between them is stable
    }

    func testMergeDualTrackDiarization_emptyMic() {
        let appDiarization = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0]]
        )

        let micDiarization = DiarizationResult(
            segments: [],
            speakingTimes: [:],
            autoNames: [:],
            embeddings: nil
        )

        let merged = DiarizationProcess.mergeDualTrackDiarization(
            appDiarization: appDiarization,
            micDiarization: micDiarization
        )

        XCTAssertEqual(merged.segments.count, 1)
        XCTAssertEqual(merged.segments[0].speaker, "R_SPEAKER_0")
    }

    func testAssignSpeakersDualTrack() {
        let appSegments = [
            TimestampedSegment(start: 0, end: 5, text: "Remote talking"),
            TimestampedSegment(start: 10, end: 15, text: "Another remote"),
        ]
        let micSegments = [
            TimestampedSegment(start: 5, end: 10, text: "Local talking"),
        ]

        let appDiarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 6, speaker: "R_SPEAKER_0"),
                .init(start: 8, end: 15, speaker: "R_SPEAKER_1"),
            ],
            speakingTimes: ["R_SPEAKER_0": 6, "R_SPEAKER_1": 7],
            autoNames: ["R_SPEAKER_0": "Anna", "R_SPEAKER_1": "Max"],
            embeddings: nil
        )

        let micDiarization = DiarizationResult(
            segments: [
                .init(start: 4, end: 11, speaker: "M_SPEAKER_0"),
            ],
            speakingTimes: ["M_SPEAKER_0": 7],
            autoNames: ["M_SPEAKER_0": "Roman"],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakersDualTrack(
            appSegments: appSegments,
            micSegments: micSegments,
            appDiarization: appDiarization,
            micDiarization: micDiarization
        )

        // Sorted by start time
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].speaker, "Anna")    // app 0-5 overlaps R_SPEAKER_0
        XCTAssertEqual(result[1].speaker, "Roman")   // mic 5-10 overlaps M_SPEAKER_0
        XCTAssertEqual(result[2].speaker, "Max")     // app 10-15 overlaps R_SPEAKER_1
    }

    func testAssignSpeakersDualTrack_noOverlapFallback() {
        let appSegments = [
            TimestampedSegment(start: 50, end: 55, text: "Far away"),
        ]

        let appDiarization = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "R_SPEAKER_0")],
            speakingTimes: ["R_SPEAKER_0": 5],
            autoNames: ["R_SPEAKER_0": "Anna"],
            embeddings: nil
        )

        let micDiarization = DiarizationResult(
            segments: [],
            speakingTimes: [:],
            autoNames: [:],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakersDualTrack(
            appSegments: appSegments,
            micSegments: [],
            appDiarization: appDiarization,
            micDiarization: micDiarization
        )

        // Nearest fallback: Anna
        XCTAssertEqual(result[0].speaker, "Anna")
    }

    func testAssignSpeakersHybrid_appNoOverlapKeepsRemote() {
        let appSegments = [
            TimestampedSegment(start: 50, end: 55, text: "Far away segment"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            autoNames: ["SPEAKER_0": "Roman", "SPEAKER_1": "Anna"],
            embeddings: nil
        )

        let result = DiarizationProcess.assignSpeakersHybrid(
            appSegments: appSegments,
            micSegments: [],
            diarization: diarization,
            micSpeakerID: "SPEAKER_0",
            micLabel: "Me"
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "Remote")
    }
}
