@testable import MeetingTranscriber
import XCTest

final class DiarizationProcessTests: XCTestCase { // swiftlint:disable:this type_body_length
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
            embeddings: nil,
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization,
        )

        XCTAssertEqual(result[0].speaker, "Alice") // 0-5 overlaps Alice (0-6)
        XCTAssertEqual(result[1].speaker, "Bob") // 5-10: 1s Alice, 4s Bob -> Bob
        XCTAssertEqual(result[2].speaker, "Bob") // 10-15 fully Bob
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
            embeddings: nil,
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization,
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
            embeddings: nil,
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization,
        )

        XCTAssertEqual(result[0].speaker, "Roman")
        XCTAssertEqual(result[1].speaker, "Anna")
    }

    func testAssignSpeakersEmpty() {
        let result = DiarizationProcess.assignSpeakers(
            transcript: [],
            diarization: DiarizationResult(segments: [], speakingTimes: [:], autoNames: [:], embeddings: nil),
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
            embeddings: nil,
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization,
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
            embeddings: nil,
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization,
        )

        // No diarization segments at all → UNKNOWN
        XCTAssertEqual(result[0].speaker, "UNKNOWN")
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
            embeddings: ["SPEAKER_0": [1, 0], "SPEAKER_1": [0, 1]],
        )

        let micDiarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 8, speaker: "SPEAKER_0"),
            ],
            speakingTimes: ["SPEAKER_0": 8],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [0.5, 0.5]],
        )

        let merged = DiarizationProcess.mergeDualTrackDiarization(
            appDiarization: appDiarization,
            micDiarization: micDiarization,
        )

        // App speakers prefixed with R_, mic with M_
        XCTAssertEqual(merged.segments.count, 3)
        let speakers = Set(merged.segments.map(\.speaker))
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
            embeddings: ["SPEAKER_0": [1, 0]],
        )

        let micDiarization = DiarizationResult(
            segments: [],
            speakingTimes: [:],
            autoNames: [:],
            embeddings: nil,
        )

        let merged = DiarizationProcess.mergeDualTrackDiarization(
            appDiarization: appDiarization,
            micDiarization: micDiarization,
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
            embeddings: nil,
        )

        let micDiarization = DiarizationResult(
            segments: [
                .init(start: 4, end: 11, speaker: "M_SPEAKER_0"),
            ],
            speakingTimes: ["M_SPEAKER_0": 7],
            autoNames: ["M_SPEAKER_0": "Roman"],
            embeddings: nil,
        )

        let result = DiarizationProcess.assignSpeakersDualTrack(
            appSegments: appSegments,
            micSegments: micSegments,
            appDiarization: appDiarization,
            micDiarization: micDiarization,
        )

        // Sorted by start time
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].speaker, "Anna") // app 0-5 overlaps R_SPEAKER_0
        XCTAssertEqual(result[1].speaker, "Roman") // mic 5-10 overlaps M_SPEAKER_0
        XCTAssertEqual(result[2].speaker, "Max") // app 10-15 overlaps R_SPEAKER_1
    }

    func testMergeDualTrackDiarization_prefixesAutoNames() {
        let appDiar = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: ["SPEAKER_0": "Anna"],
            embeddings: nil,
        )
        let micDiar = DiarizationResult(
            segments: [.init(start: 0, end: 3, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 3],
            autoNames: ["SPEAKER_0": "Roman"],
            embeddings: nil,
        )

        let merged = DiarizationProcess.mergeDualTrackDiarization(
            appDiarization: appDiar, micDiarization: micDiar,
        )

        XCTAssertEqual(merged.autoNames["R_SPEAKER_0"], "Anna")
        XCTAssertEqual(merged.autoNames["M_SPEAKER_0"], "Roman")
    }

    func testMergeDualTrackDiarization_nilEmbeddingsBothSides() {
        let appDiar = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "S0")],
            speakingTimes: ["S0": 5], autoNames: [:], embeddings: nil,
        )
        let micDiar = DiarizationResult(
            segments: [], speakingTimes: [:], autoNames: [:], embeddings: nil,
        )

        let merged = DiarizationProcess.mergeDualTrackDiarization(
            appDiarization: appDiar, micDiarization: micDiar,
        )

        XCTAssertNil(merged.embeddings)
    }

    // MARK: - Merge Consecutive Speakers

    func testMergeConsecutiveSpeakers() {
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "Hello there.", speaker: "Alice"),
            TimestampedSegment(start: 5, end: 10, text: "How are you?", speaker: "Alice"),
            TimestampedSegment(start: 10, end: 15, text: "I'm fine.", speaker: "Bob"),
            TimestampedSegment(start: 15, end: 20, text: "Thanks.", speaker: "Bob"),
            TimestampedSegment(start: 20, end: 25, text: "Great!", speaker: "Alice"),
        ]

        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].speaker, "Alice")
        XCTAssertEqual(merged[0].text, "Hello there. How are you?")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 10)
        XCTAssertEqual(merged[1].speaker, "Bob")
        XCTAssertEqual(merged[1].text, "I'm fine. Thanks.")
        XCTAssertEqual(merged[1].start, 10)
        XCTAssertEqual(merged[1].end, 20)
        XCTAssertEqual(merged[2].speaker, "Alice")
        XCTAssertEqual(merged[2].text, "Great!")
        XCTAssertEqual(merged[2].start, 20)
        XCTAssertEqual(merged[2].end, 25)
    }

    func testMergeConsecutiveSpeakers_empty() {
        let merged = DiarizationProcess.mergeConsecutiveSpeakers([])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergeConsecutiveSpeakers_singleSegment() {
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "Hello", speaker: "Alice"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "Hello")
    }

    func testMergeConsecutiveSpeakers_allSameSpeaker() {
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "One.", speaker: "Alice"),
            TimestampedSegment(start: 5, end: 10, text: "Two.", speaker: "Alice"),
            TimestampedSegment(start: 10, end: 15, text: "Three.", speaker: "Alice"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "One. Two. Three.")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 15)
    }

    func testMergeConsecutiveSpeakers_allDifferent() {
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "A", speaker: "Alice"),
            TimestampedSegment(start: 5, end: 10, text: "B", speaker: "Bob"),
            TimestampedSegment(start: 10, end: 15, text: "C", speaker: "Carol"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 3)
    }

    func testMergeConsecutiveSpeakers_silenceGapBreaksSameSpeaker() {
        // Same speaker but >2s gap between segments — should NOT merge
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "First thought.", speaker: "Alice"),
            TimestampedSegment(start: 8, end: 13, text: "Second thought.", speaker: "Alice"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 2, "Silence gap >2s should break same-speaker block")
        XCTAssertEqual(merged[0].text, "First thought.")
        XCTAssertEqual(merged[1].text, "Second thought.")
    }

    func testMergeConsecutiveSpeakers_smallGapStillMerges() {
        // Same speaker with <2s gap — should merge
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "Hello.", speaker: "Alice"),
            TimestampedSegment(start: 6, end: 10, text: "How are you?", speaker: "Alice"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 1, "Small gap should still merge")
        XCTAssertEqual(merged[0].text, "Hello. How are you?")
    }

    func testMergeConsecutiveSpeakers_exactThresholdMerges() {
        // Gap exactly at threshold (2.0s) — should still merge
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "A.", speaker: "Alice"),
            TimestampedSegment(start: 7, end: 10, text: "B.", speaker: "Alice"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 1, "Gap exactly at threshold should merge")
    }

    func testMergeConsecutiveSpeakers_longMonologBrokenByPauses() {
        // Simulates a long monolog with natural pauses — should break into blocks
        let segments = [
            TimestampedSegment(start: 0, end: 10, text: "First paragraph.", speaker: "Roman"),
            TimestampedSegment(start: 10.5, end: 20, text: "Still first.", speaker: "Roman"),
            TimestampedSegment(start: 23, end: 30, text: "Second paragraph.", speaker: "Roman"),
            TimestampedSegment(start: 30.5, end: 40, text: "Still second.", speaker: "Roman"),
            TimestampedSegment(start: 45, end: 55, text: "Third paragraph.", speaker: "Roman"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 3, "Long monolog should break at natural pauses")
        XCTAssertEqual(merged[0].text, "First paragraph. Still first.")
        XCTAssertEqual(merged[1].text, "Second paragraph. Still second.")
        XCTAssertEqual(merged[2].text, "Third paragraph.")
    }

    func testDiarizationErrorDescription() {
        let error: DiarizationError = .notAvailable
        XCTAssertEqual(error.errorDescription, "Diarization not available")
    }

    func testAssignSpeakersDualTrack_noOverlapFallback() {
        let appSegments = [
            TimestampedSegment(start: 50, end: 55, text: "Far away"),
        ]

        let appDiarization = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "R_SPEAKER_0")],
            speakingTimes: ["R_SPEAKER_0": 5],
            autoNames: ["R_SPEAKER_0": "Anna"],
            embeddings: nil,
        )

        let micDiarization = DiarizationResult(
            segments: [],
            speakingTimes: [:],
            autoNames: [:],
            embeddings: nil,
        )

        let result = DiarizationProcess.assignSpeakersDualTrack(
            appSegments: appSegments,
            micSegments: [],
            appDiarization: appDiarization,
            micDiarization: micDiarization,
        )

        // Nearest fallback: Anna
        XCTAssertEqual(result[0].speaker, "Anna")
    }

    // MARK: - Edge Cases

    func testAssignSpeakersPreservesText() {
        let transcript = [
            TimestampedSegment(start: 0, end: 5, text: "Important text here"),
        ]
        let diarization = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "Alice")],
            speakingTimes: ["Alice": 5],
            autoNames: [:],
            embeddings: nil,
        )
        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization,
        )
        XCTAssertEqual(result[0].text, "Important text here")
    }

    func testAssignSpeakersPreservesTimestamps() {
        let transcript = [
            TimestampedSegment(start: 3.5, end: 7.2, text: "Hello"),
        ]
        let diarization = DiarizationResult(
            segments: [.init(start: 0, end: 10, speaker: "Speaker")],
            speakingTimes: ["Speaker": 10],
            autoNames: [:],
            embeddings: nil,
        )
        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization,
        )
        XCTAssertEqual(result[0].start, 3.5)
        XCTAssertEqual(result[0].end, 7.2)
    }

    func testMergeDualTrackSortsByStartTime() {
        let appDiar = DiarizationResult(
            segments: [.init(start: 5, end: 10, speaker: "S0")],
            speakingTimes: ["S0": 5], autoNames: [:], embeddings: nil,
        )
        let micDiar = DiarizationResult(
            segments: [.init(start: 0, end: 3, speaker: "S0")],
            speakingTimes: ["S0": 3], autoNames: [:], embeddings: nil,
        )
        let merged = DiarizationProcess.mergeDualTrackDiarization(
            appDiarization: appDiar, micDiarization: micDiar,
        )
        // Mic segment (start=0) should come before app segment (start=5)
        XCTAssertEqual(merged.segments[0].speaker, "M_S0")
        XCTAssertEqual(merged.segments[1].speaker, "R_S0")
    }

    func testAssignSpeakersDualTrackEmptyBothTracks() {
        let emptyDiar = DiarizationResult(
            segments: [], speakingTimes: [:], autoNames: [:], embeddings: nil,
        )
        let result = DiarizationProcess.assignSpeakersDualTrack(
            appSegments: [],
            micSegments: [],
            appDiarization: emptyDiar,
            micDiarization: emptyDiar,
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testMergeGapThresholdValue() {
        XCTAssertEqual(DiarizationProcess.mergeGapThreshold, 2.0)
    }

    func testMergeConsecutiveSpeakers_gapJustOverThreshold() {
        // Gap of 2.001s (just over 2.0s threshold) — should NOT merge
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "First part.", speaker: "Alice"),
            TimestampedSegment(start: 7.001, end: 10, text: "Second part.", speaker: "Alice"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 2, "Gap of 2.001s exceeds threshold — should not merge")
        XCTAssertEqual(merged[0].text, "First part.")
        XCTAssertEqual(merged[0].end, 5)
        XCTAssertEqual(merged[1].text, "Second part.")
        XCTAssertEqual(merged[1].start, 7.001)
    }

    func testMergeConsecutiveSpeakers_overlappingSegments() {
        // Negative gap (overlapping segments) — same speaker should merge
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "Overlapping start.", speaker: "Alice"),
            TimestampedSegment(start: 4, end: 8, text: "Overlapping end.", speaker: "Alice"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 1, "Negative gap (overlap) should merge same speaker")
        XCTAssertEqual(merged[0].text, "Overlapping start. Overlapping end.")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 8)
    }

    func testMergeConsecutiveSpeakers_rapidSpeakerAlternation() {
        // A, B, A, B — different speakers should never merge even with no gap
        let segments = [
            TimestampedSegment(start: 0, end: 2, text: "A1", speaker: "Alice"),
            TimestampedSegment(start: 2, end: 4, text: "B1", speaker: "Bob"),
            TimestampedSegment(start: 4, end: 6, text: "A2", speaker: "Alice"),
            TimestampedSegment(start: 6, end: 8, text: "B2", speaker: "Bob"),
        ]
        let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments)
        XCTAssertEqual(merged.count, 4, "Rapid A-B-A-B alternation should stay as 4 segments")
        XCTAssertEqual(merged[0].speaker, "Alice")
        XCTAssertEqual(merged[1].speaker, "Bob")
        XCTAssertEqual(merged[2].speaker, "Alice")
        XCTAssertEqual(merged[3].speaker, "Bob")
    }

    func testAssignSpeakersDualTrackSortsByStartTime() {
        let appSegments = [
            TimestampedSegment(start: 10, end: 15, text: "Late app"),
        ]
        let micSegments = [
            TimestampedSegment(start: 2, end: 5, text: "Early mic"),
        ]
        let appDiar = DiarizationResult(
            segments: [.init(start: 8, end: 16, speaker: "R_S0")],
            speakingTimes: ["R_S0": 8], autoNames: [:], embeddings: nil,
        )
        let micDiar = DiarizationResult(
            segments: [.init(start: 0, end: 6, speaker: "M_S0")],
            speakingTimes: ["M_S0": 6], autoNames: [:], embeddings: nil,
        )
        let result = DiarizationProcess.assignSpeakersDualTrack(
            appSegments: appSegments,
            micSegments: micSegments,
            appDiarization: appDiar,
            micDiarization: micDiar,
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "Early mic")
        XCTAssertEqual(result[1].text, "Late app")
    }
}
