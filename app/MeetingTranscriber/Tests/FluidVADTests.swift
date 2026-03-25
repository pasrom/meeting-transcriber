@testable import MeetingTranscriber
import XCTest

final class VadSegmentMapTests: XCTestCase {
    // MARK: - mapToOriginal

    func testSingleSegmentMapping() {
        // Original audio: speech from 5.0–10.0s → trimmed audio: 0.0–5.0s
        let map = VadSegmentMap(
            entries: [
                .init(originalStart: 5.0, originalEnd: 10.0, trimmedStart: 0.0),
            ],
            totalTrimmedDuration: 5.0
        )

        XCTAssertEqual(map.mapToOriginal(0.0), 5.0, accuracy: 0.001)
        XCTAssertEqual(map.mapToOriginal(2.5), 7.5, accuracy: 0.001)
        XCTAssertEqual(map.mapToOriginal(5.0), 10.0, accuracy: 0.001)
    }

    func testMultiSegmentWithGaps() {
        // Original: speech at 2–4s, 8–12s, 20–22s
        // Trimmed: 0–2s, 2–6s, 6–8s
        let map = VadSegmentMap(
            entries: [
                .init(originalStart: 2.0, originalEnd: 4.0, trimmedStart: 0.0),
                .init(originalStart: 8.0, originalEnd: 12.0, trimmedStart: 2.0),
                .init(originalStart: 20.0, originalEnd: 22.0, trimmedStart: 6.0),
            ],
            totalTrimmedDuration: 8.0
        )

        // First segment
        XCTAssertEqual(map.mapToOriginal(0.0), 2.0, accuracy: 0.001)
        XCTAssertEqual(map.mapToOriginal(1.0), 3.0, accuracy: 0.001)

        // Second segment
        XCTAssertEqual(map.mapToOriginal(2.0), 8.0, accuracy: 0.001)
        XCTAssertEqual(map.mapToOriginal(4.0), 10.0, accuracy: 0.001)

        // Third segment
        XCTAssertEqual(map.mapToOriginal(6.0), 20.0, accuracy: 0.001)
        XCTAssertEqual(map.mapToOriginal(7.5), 21.5, accuracy: 0.001)
    }

    func testBeyondLastSegmentClampsToEnd() {
        let map = VadSegmentMap(
            entries: [
                .init(originalStart: 1.0, originalEnd: 3.0, trimmedStart: 0.0),
            ],
            totalTrimmedDuration: 2.0
        )

        XCTAssertEqual(map.mapToOriginal(10.0), 3.0, accuracy: 0.001)
    }

    func testEmptyMapReturnsInput() {
        let map = VadSegmentMap(entries: [], totalTrimmedDuration: 0)

        XCTAssertEqual(map.mapToOriginal(5.0), 5.0, accuracy: 0.001)
    }

    func testAtSegmentBoundary() {
        let map = VadSegmentMap(
            entries: [
                .init(originalStart: 0.0, originalEnd: 3.0, trimmedStart: 0.0),
                .init(originalStart: 5.0, originalEnd: 8.0, trimmedStart: 3.0),
            ],
            totalTrimmedDuration: 6.0
        )

        // At the exact end of first segment / start of second
        XCTAssertEqual(map.mapToOriginal(3.0), 5.0, accuracy: 0.001)
    }

    // MARK: - hasSpeech

    func testHasSpeechWithEntries() {
        let map = VadSegmentMap(
            entries: [.init(originalStart: 0, originalEnd: 1, trimmedStart: 0)],
            totalTrimmedDuration: 1.0
        )
        XCTAssertTrue(map.hasSpeech)
    }

    func testHasSpeechEmpty() {
        let map = VadSegmentMap(entries: [], totalTrimmedDuration: 0)
        XCTAssertFalse(map.hasSpeech)
    }

    // MARK: - build

    func testBuildFromSegments() {
        let segments = [
            MockVadSegment(startTime: 1.0, endTime: 3.0),
            MockVadSegment(startTime: 5.0, endTime: 7.0),
        ]

        let map = VadSegmentMap.build(from: segments)

        XCTAssertEqual(map.entries.count, 2)
        XCTAssertEqual(map.totalTrimmedDuration, 4.0, accuracy: 0.001)

        XCTAssertEqual(map.entries[0].trimmedStart, 0.0, accuracy: 0.001)
        XCTAssertEqual(map.entries[0].originalStart, 1.0, accuracy: 0.001)

        XCTAssertEqual(map.entries[1].trimmedStart, 2.0, accuracy: 0.001)
        XCTAssertEqual(map.entries[1].originalStart, 5.0, accuracy: 0.001)
    }
}

// MARK: - AudioMixer.extractSegments

final class AudioMixerExtractSegmentsTests: XCTestCase {
    func testExtractSingleSegment() {
        let samples: [Float] = Array(repeating: 1.0, count: 16000) // 1 second at 16kHz
        let result = AudioMixer.extractSegments(
            from: samples,
            sampleRate: 16000,
            segments: [(start: 0.25, end: 0.75)]
        )
        XCTAssertEqual(result.count, 8000) // 0.5s
    }

    func testExtractMultipleSegments() {
        // 2 seconds of audio
        var samples = [Float](repeating: 0, count: 32000)
        // Fill second half with 1s
        for i in 16000 ..< 32000 { samples[i] = 1.0 }

        let result = AudioMixer.extractSegments(
            from: samples,
            sampleRate: 16000,
            segments: [(start: 0.0, end: 0.5), (start: 1.0, end: 1.5)]
        )

        XCTAssertEqual(result.count, 16000) // 0.5s + 0.5s
        XCTAssertEqual(result[0], 0.0) // from first half
        XCTAssertEqual(result[8000], 1.0) // from second half
    }

    func testExtractEmptySegments() {
        let samples: [Float] = [1, 2, 3, 4]
        let result = AudioMixer.extractSegments(
            from: samples,
            sampleRate: 16000,
            segments: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testExtractClampsBeyondLength() {
        let samples: [Float] = Array(repeating: 1.0, count: 16000)
        let result = AudioMixer.extractSegments(
            from: samples,
            sampleRate: 16000,
            segments: [(start: 0.5, end: 5.0)] // extends beyond audio
        )
        XCTAssertEqual(result.count, 8000) // clamped to 0.5–1.0s
    }
}

// MARK: - Mock VadSegment for tests

/// Lightweight stand-in for FluidAudio's VadSegment so tests compile without the framework.
private struct MockVadSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

extension VadSegmentMap {
    /// Test-only convenience using mock segments.
    fileprivate static func build(from segments: [MockVadSegment]) -> VadSegmentMap {
        var entries: [Entry] = []
        var trimmedOffset: TimeInterval = 0
        for seg in segments {
            entries.append(Entry(
                originalStart: seg.startTime,
                originalEnd: seg.endTime,
                trimmedStart: trimmedOffset
            ))
            trimmedOffset += seg.endTime - seg.startTime
        }
        return VadSegmentMap(entries: entries, totalTrimmedDuration: trimmedOffset)
    }
}
