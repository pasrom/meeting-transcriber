@testable import MeetingTranscriber
import XCTest

/// Tests for the pure helper that picks a temporally-pure sample segment
/// for the speaker-naming dialog playback. Lives in its own file so the
/// main `SpeakerNamingViewTests` body stays under SwiftLint's 400-line cap.
@MainActor
final class SelectSampleSegmentTests: XCTestCase {
    private typealias Seg = PipelineQueue.SpeakerNamingData.Segment

    func testSelectSampleSegmentReturnsLoneIsolatedSegment() {
        // SPEAKER_0 has a single isolated segment, no other speakers nearby.
        let segments: [Seg] = [
            Seg(start: 0.0, end: 4.0, speaker: "SPEAKER_0"),
            Seg(start: 20.0, end: 25.0, speaker: "SPEAKER_1"),
        ]
        let result = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: segments)
        XCTAssertEqual(result?.start, 0.0)
        XCTAssertEqual(result?.end, 4.0)
    }

    func testSelectSampleSegmentPrefersShorterPureOverLongerContaminated() {
        // The 10s segment is contaminated (SPEAKER_1 cuts in within ±0.5s).
        // The shorter 2s segment is pure and ≥ minDuration → must win.
        let segments: [Seg] = [
            Seg(start: 0.0, end: 10.0, speaker: "SPEAKER_0"), // contaminated
            Seg(start: 9.8, end: 12.0, speaker: "SPEAKER_1"), // overlaps the long one
            Seg(start: 30.0, end: 32.0, speaker: "SPEAKER_0"), // pure, 2s
        ]
        let result = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: segments)
        XCTAssertEqual(result?.start, 30.0)
        XCTAssertEqual(result?.end, 32.0)
    }

    func testSelectSampleSegmentFallsBackToLongestWhenAllContaminated() {
        // Every SPEAKER_0 segment has another speaker within ±0.5s.
        let segments: [Seg] = [
            Seg(start: 0.0, end: 4.0, speaker: "SPEAKER_0"),
            Seg(start: 4.2, end: 6.0, speaker: "SPEAKER_1"), // contaminates [0,4]
            Seg(start: 10.0, end: 18.0, speaker: "SPEAKER_0"), // longest
            Seg(start: 17.5, end: 20.0, speaker: "SPEAKER_1"), // contaminates [10,18]
        ]
        let result = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: segments)
        XCTAssertEqual(result?.start, 10.0)
        XCTAssertEqual(result?.end, 18.0)
    }

    func testSelectSampleSegmentFallsBackWhenPureSegmentBelowMinDuration() {
        // The pure SPEAKER_0 segment is only 0.5s — below the 1.5s minDuration.
        // Must fall back to the longest overall (the contaminated 8s one).
        let segments: [Seg] = [
            Seg(start: 0.0, end: 8.0, speaker: "SPEAKER_0"), // contaminated, longest
            Seg(start: 7.8, end: 10.0, speaker: "SPEAKER_1"),
            Seg(start: 30.0, end: 30.5, speaker: "SPEAKER_0"), // pure but too short
        ]
        let result = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: segments)
        XCTAssertEqual(result?.start, 0.0)
        XCTAssertEqual(result?.end, 8.0)
    }

    func testSelectSampleSegmentReturnsNilWhenSpeakerHasNoSegments() {
        let segments: [Seg] = [
            Seg(start: 0.0, end: 5.0, speaker: "SPEAKER_1"),
            Seg(start: 5.0, end: 10.0, speaker: "SPEAKER_2"),
        ]
        let result = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: segments)
        XCTAssertNil(result)
    }

    func testSelectSampleSegmentZeroGapCountsAsContamination() {
        // SPEAKER_1 starts exactly at SPEAKER_0.end → zero gap.
        // Zero gap < purityWindow (0.5) → counts as overlap → contaminated.
        // Should fall back to longest overall.
        let segments: [Seg] = [
            Seg(start: 0.0, end: 5.0, speaker: "SPEAKER_0"),
            Seg(start: 5.0, end: 8.0, speaker: "SPEAKER_1"),
        ]
        let result = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: segments)
        // Only one SPEAKER_0 segment, contaminated → fallback returns it anyway.
        XCTAssertEqual(result?.start, 0.0)
        XCTAssertEqual(result?.end, 5.0)

        // Add a shorter pure segment ≥ minDuration; the contaminated one must lose now.
        let withPure: [Seg] = segments + [
            Seg(start: 30.0, end: 32.0, speaker: "SPEAKER_0"),
        ]
        let r2 = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: withPure)
        XCTAssertEqual(r2?.start, 30.0)
        XCTAssertEqual(r2?.end, 32.0)
    }

    func testSelectSampleSegmentExactBoundaryNotContaminated() {
        // SPEAKER_1 starts at SPEAKER_0.end + purityWindow (exactly 0.5s gap).
        // Overlap test is strict (a < d && c < b); a window edge that just
        // touches another segment does NOT overlap → segment stays pure.
        let segments: [Seg] = [
            Seg(start: 0.0, end: 5.0, speaker: "SPEAKER_0"),
            Seg(start: 5.5, end: 8.0, speaker: "SPEAKER_1"), // exactly at boundary
        ]
        let result = SpeakerNamingView.selectSampleSegment(for: "SPEAKER_0", in: segments)
        XCTAssertEqual(result?.start, 0.0)
        XCTAssertEqual(result?.end, 5.0)
    }
}
