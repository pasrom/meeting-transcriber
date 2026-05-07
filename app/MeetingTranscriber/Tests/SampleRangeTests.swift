@testable import MeetingTranscriber
import XCTest

/// Tests for the pure helper that maps a (start, end) seconds range to a
/// clamped half-open sample range. Lives in its own file to keep
/// `SpeakerNamingViewTests` under SwiftLint's `type_body_length` cap.
final class SampleRangeTests: XCTestCase {
    func testSampleRangeIntegerBoundaries() {
        let result = SpeakerNamingView.sampleRange(
            start: 1.0, end: 3.0, sampleRate: 16000, totalSamples: 100_000,
        )
        XCTAssertEqual(result, 16000 ..< 48000)
    }

    func testSampleRangeFractionalBoundariesPreservePrecision() {
        // start = 1.7s at 16kHz must yield 27200, NOT 16000 (which is what
        // `Int(1.7) * 16000 = 1 * 16000` would produce).
        let result = SpeakerNamingView.sampleRange(
            start: 1.7, end: 3.7, sampleRate: 16000, totalSamples: 100_000,
        )
        XCTAssertEqual(result, 27200 ..< 59200)
    }

    func testSampleRangeClampsEndToTotalSamples() {
        let result = SpeakerNamingView.sampleRange(
            start: 0.0, end: 100.0, sampleRate: 16000, totalSamples: 50000,
        )
        XCTAssertEqual(result, 0 ..< 50000)
    }

    func testSampleRangeClampsNegativeStartToZero() {
        let result = SpeakerNamingView.sampleRange(
            start: -0.5, end: 2.0, sampleRate: 16000, totalSamples: 100_000,
        )
        XCTAssertEqual(result?.lowerBound, 0)
        XCTAssertEqual(result?.upperBound, 32000)
    }

    func testSampleRangeReturnsNilForZeroDuration() {
        let result = SpeakerNamingView.sampleRange(
            start: 1.0, end: 1.0, sampleRate: 16000, totalSamples: 100_000,
        )
        XCTAssertNil(result)
    }

    func testSampleRangeReturnsNilWhenStartAfterEnd() {
        let result = SpeakerNamingView.sampleRange(
            start: 5.0, end: 3.0, sampleRate: 16000, totalSamples: 100_000,
        )
        XCTAssertNil(result)
    }
}
