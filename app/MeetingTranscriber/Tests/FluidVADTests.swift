@testable import MeetingTranscriber
import XCTest

final class FluidVADTests: XCTestCase {
    // MARK: - VadSegmentMap Tests

    func testSegmentMapEmpty() {
        let map = VadSegmentMap(segments: [], sampleRate: 16000)
        XCTAssertEqual(map.originalDuration, 0)
        XCTAssertEqual(map.trimmedDuration, 0)
    }

    func testSegmentMapSingleSegment() {
        // Single speech region from 1.0s to 3.0s (duration = 2.0s)
        let map = VadSegmentMap(
            segments: [SpeechRegion(start: 1.0, end: 3.0)],
            sampleRate: 16000,
        )

        XCTAssertEqual(map.originalDuration, 3.0)
        XCTAssertEqual(map.trimmedDuration, 2.0, accuracy: 1e-9)

        // Trimmed time 0.0 maps to original time 1.0 (start of first segment)
        XCTAssertEqual(map.toOriginalTime(0.0), 1.0, accuracy: 1e-9)

        // Trimmed time 1.5 maps to original time 2.5 (1.0 + 1.5)
        XCTAssertEqual(map.toOriginalTime(1.5), 2.5, accuracy: 1e-9)

        // Trimmed time 2.0 maps to original time 3.0 (end of segment)
        XCTAssertEqual(map.toOriginalTime(2.0), 3.0, accuracy: 1e-9)
    }

    func testSegmentMapMultipleSegments() {
        // Two speech regions: 1.0–2.0 (1s) and 4.0–5.0 (1s)
        let map = VadSegmentMap(
            segments: [
                SpeechRegion(start: 1.0, end: 2.0),
                SpeechRegion(start: 4.0, end: 5.0),
            ],
            sampleRate: 16000,
        )

        XCTAssertEqual(map.originalDuration, 5.0)
        XCTAssertEqual(map.trimmedDuration, 2.0, accuracy: 1e-9)

        // Trimmed 0.0 → original 1.0 (start of first segment)
        XCTAssertEqual(map.toOriginalTime(0.0), 1.0, accuracy: 1e-9)

        // Trimmed 0.5 → original 1.5 (middle of first segment)
        XCTAssertEqual(map.toOriginalTime(0.5), 1.5, accuracy: 1e-9)

        // Trimmed 1.0 → original 2.0 (end of first segment)
        XCTAssertEqual(map.toOriginalTime(1.0), 2.0, accuracy: 1e-9)

        // Trimmed 1.5 → original 4.5 (middle of second segment)
        XCTAssertEqual(map.toOriginalTime(1.5), 4.5, accuracy: 1e-9)

        // Trimmed 2.0 → original 5.0 (end of second segment)
        XCTAssertEqual(map.toOriginalTime(2.0), 5.0, accuracy: 1e-9)
    }

    func testSegmentMapRemapsTranscriptSegments() {
        // Speech regions: 1.0–2.0 and 4.0–5.0
        let map = VadSegmentMap(
            segments: [
                SpeechRegion(start: 1.0, end: 2.0),
                SpeechRegion(start: 4.0, end: 5.0),
            ],
            sampleRate: 16000,
        )

        let transcript = [
            TimestampedSegment(start: 0.0, end: 0.8, text: "Hello"),
            TimestampedSegment(start: 1.0, end: 1.8, text: "World"),
        ]

        let remapped = map.remapTimestamps(transcript)

        // First segment: 0.0 → 1.0, 0.8 → 1.8
        XCTAssertEqual(remapped[0].start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(remapped[0].end, 1.8, accuracy: 1e-9)
        XCTAssertEqual(remapped[0].text, "Hello")

        // Second segment: 1.0 → 2.0 (end of first speech region),
        // but actually 1.0 maps to end of first region = 2.0
        // 1.8 maps into second region: 1.8 - 1.0 = 0.8 into second region → 4.0 + 0.8 = 4.8
        XCTAssertEqual(remapped[1].start, 2.0, accuracy: 1e-9)
        XCTAssertEqual(remapped[1].end, 4.8, accuracy: 1e-9)
        XCTAssertEqual(remapped[1].text, "World")
    }

    func testExtractSpeechSamples() {
        // Use 100 Hz sample rate for easy math
        let map = VadSegmentMap(
            segments: [
                SpeechRegion(start: 1.0, end: 2.0), // samples 100–199
                SpeechRegion(start: 3.0, end: 4.0), // samples 300–399
            ],
            sampleRate: 100,
        )

        // Create audio: 500 samples (5 seconds at 100 Hz)
        // Each sample = its index for easy verification
        let audio = (0 ..< 500).map { Float($0) }

        let extracted = map.extractSpeechSamples(from: audio)

        // Should have 200 samples (100 from each region)
        XCTAssertEqual(extracted.count, 200)

        // First 100 samples should be from indices 100–199
        XCTAssertEqual(extracted[0], 100.0)
        XCTAssertEqual(extracted[99], 199.0)

        // Next 100 samples should be from indices 300–399
        XCTAssertEqual(extracted[100], 300.0)
        XCTAssertEqual(extracted[199], 399.0)
    }

    func testSpeechRegionDuration() {
        let region = SpeechRegion(start: 1.5, end: 3.5)
        XCTAssertEqual(region.duration, 2.0, accuracy: 1e-9)
    }

    // MARK: - Boundary Condition Tests

    func testToOriginalTimeBeyondAllSegments() {
        // Two segments: 1.0–2.0 (1s) and 4.0–5.0 (1s), total speech = 2s
        let map = VadSegmentMap(
            segments: [
                SpeechRegion(start: 1.0, end: 2.0),
                SpeechRegion(start: 4.0, end: 5.0),
            ],
            sampleRate: 16000,
        )

        // trimmedTime 3.0 exceeds total speech duration (2.0) → last segment's end (5.0)
        XCTAssertEqual(map.toOriginalTime(3.0), 5.0, accuracy: 1e-9)

        // trimmedTime 100.0 also → last segment's end
        XCTAssertEqual(map.toOriginalTime(100.0), 5.0, accuracy: 1e-9)
    }

    func testToOriginalTimeEmptySegments() {
        let map = VadSegmentMap(segments: [], sampleRate: 16000)

        // Empty segments: falls through loop, returns segments.last?.end ?? trimmedTime → input
        XCTAssertEqual(map.toOriginalTime(0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(map.toOriginalTime(2.5), 2.5, accuracy: 1e-9)
    }

    func testToOriginalTimeExactlyAtFirstSegmentEnd() {
        // Two segments: 1.0–3.0 (2s) and 5.0–7.0 (2s)
        let map = VadSegmentMap(
            segments: [
                SpeechRegion(start: 1.0, end: 3.0),
                SpeechRegion(start: 5.0, end: 7.0),
            ],
            sampleRate: 16000,
        )

        // trimmedTime == first segment duration (2.0): remaining <= segDuration is true
        // → maps to segment.start + remaining = 1.0 + 2.0 = 3.0 (end of first segment)
        XCTAssertEqual(map.toOriginalTime(2.0), 3.0, accuracy: 1e-9)

        // Just past boundary: 2.0 + epsilon → enters second segment
        let epsilon = 1e-6
        let result = map.toOriginalTime(2.0 + epsilon)
        XCTAssertEqual(result, 5.0 + epsilon, accuracy: 1e-9)
    }

    func testExtractSpeechSamplesEmptyAudio() {
        let map = VadSegmentMap(
            segments: [SpeechRegion(start: 0.0, end: 1.0)],
            sampleRate: 100,
        )

        let extracted = map.extractSpeechSamples(from: [])
        XCTAssertTrue(extracted.isEmpty)
    }

    func testExtractSpeechSamplesSegmentBeyondAudio() {
        // Segment 0.0–2.0 at 100 Hz → wants samples 0–199, but audio only has 50 samples
        let map = VadSegmentMap(
            segments: [SpeechRegion(start: 0.0, end: 2.0)],
            sampleRate: 100,
        )

        let audio = (0 ..< 50).map { Float($0) }
        let extracted = map.extractSpeechSamples(from: audio)

        // Should clamp to audio length: 50 samples instead of 200
        XCTAssertEqual(extracted.count, 50)
        XCTAssertEqual(extracted[0], 0.0)
        XCTAssertEqual(extracted[49], 49.0)
    }

    func testRemapTimestampsEmpty() {
        let map = VadSegmentMap(
            segments: [SpeechRegion(start: 1.0, end: 3.0)],
            sampleRate: 16000,
        )

        let remapped = map.remapTimestamps([])
        XCTAssertTrue(remapped.isEmpty)
    }

    func testRemapTimestampsPreservesSpeakerAndText() {
        let map = VadSegmentMap(
            segments: [SpeechRegion(start: 2.0, end: 5.0)],
            sampleRate: 16000,
        )

        let transcript = [
            TimestampedSegment(start: 0.0, end: 1.0, text: "Good morning", speaker: "R_Speaker1"),
            TimestampedSegment(start: 1.0, end: 2.0, text: "How are you?", speaker: "M_Speaker2"),
        ]

        let remapped = map.remapTimestamps(transcript)

        XCTAssertEqual(remapped.count, 2)

        // Speaker and text preserved
        XCTAssertEqual(remapped[0].speaker, "R_Speaker1")
        XCTAssertEqual(remapped[0].text, "Good morning")
        XCTAssertEqual(remapped[1].speaker, "M_Speaker2")
        XCTAssertEqual(remapped[1].text, "How are you?")

        // Timestamps remapped: 0.0 → 2.0, 1.0 → 3.0, 2.0 → 4.0
        XCTAssertEqual(remapped[0].start, 2.0, accuracy: 1e-9)
        XCTAssertEqual(remapped[0].end, 3.0, accuracy: 1e-9)
        XCTAssertEqual(remapped[1].start, 3.0, accuracy: 1e-9)
        XCTAssertEqual(remapped[1].end, 4.0, accuracy: 1e-9)
    }
}
