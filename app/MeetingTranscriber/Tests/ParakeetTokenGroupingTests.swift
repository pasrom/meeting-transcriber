import FluidAudio
@testable import MeetingTranscriber
import XCTest

final class ParakeetTokenGroupingTests: XCTestCase {
    // MARK: - groupIntoSegments

    func testGroupIntoSegmentsEmptyInputReturnsNoSegments() {
        XCTAssertTrue(ParakeetTokenGrouping.groupIntoSegments([]).isEmpty)
    }

    func testGroupIntoSegmentsSingleTokenWithoutPunctEmitsOneSegment() {
        // No terminating punctuation and below the 20-token cap → the
        // trailing-flush at the end of the loop emits the single segment.
        let segments = ParakeetTokenGrouping.groupIntoSegments([
            timing("Hello", start: 0, end: 1),
        ])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 1)
    }

    func testGroupIntoSegmentsSplitsOnPeriod() {
        let segments = ParakeetTokenGrouping.groupIntoSegments([
            timing("Hello", start: 0, end: 1),
            timing(" world.", start: 1, end: 2),
            timing(" Next", start: 2, end: 3),
            timing(" sentence.", start: 3, end: 4),
        ])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello world.")
        XCTAssertEqual(segments[1].text, "Next sentence.")
    }

    func testGroupIntoSegmentsSplitsOnExclamationAndQuestion() {
        let segments = ParakeetTokenGrouping.groupIntoSegments([
            timing("Wow", start: 0, end: 1),
            timing("!", start: 1, end: 2),
            timing("Really", start: 2, end: 3),
            timing("?", start: 3, end: 4),
        ])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Wow!")
        XCTAssertEqual(segments[1].text, "Really?")
    }

    func testGroupIntoSegmentsForcesSplitAt20TokenCap() {
        // 25 tokens with no punctuation — must split at the 20-token cap.
        let timings = (0 ..< 25).map { i in
            timing("w\(i) ", start: Double(i), end: Double(i) + 1)
        }
        let segments = ParakeetTokenGrouping.groupIntoSegments(timings)
        XCTAssertEqual(segments.count, 2, "First segment caps at 20; remaining 5 flush at end")
        // First segment: w0..w19
        XCTAssertTrue(segments[0].text.hasPrefix("w0"))
        XCTAssertTrue(segments[0].text.contains("w19"))
        XCTAssertFalse(segments[0].text.contains("w20"))
        // Second segment: w20..w24
        XCTAssertTrue(segments[1].text.contains("w24"))
    }

    func testGroupIntoSegmentsSkipsBlankTokensInsideGroup() {
        // Whitespace-only tokens must not count toward the 20-cap and must
        // not appear in the joined text. They're stripped before grouping.
        let segments = ParakeetTokenGrouping.groupIntoSegments([
            timing("Hello", start: 0, end: 1),
            timing("   ", start: 1, end: 1.5),
            timing("\t", start: 1.5, end: 2),
            timing(" world.", start: 2, end: 3),
        ])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello world.")
    }

    func testGroupIntoSegmentsPreservesFirstAndLastTimestamps() {
        let segments = ParakeetTokenGrouping.groupIntoSegments([
            timing("A", start: 1.5, end: 2.0),
            timing(" B", start: 2.0, end: 2.4),
            timing(" C.", start: 2.4, end: 3.1),
        ])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 1.5, "Start = first token's startTime")
        XCTAssertEqual(segments[0].end, 3.1, "End = last token's endTime")
    }

    func testGroupIntoSegmentsTrailingPartialGroupFlushed() {
        // After the punct-terminated first sentence, two more tokens have
        // no terminator — the trailing-flush at the end of groupIntoSegments
        // must still emit them as a second segment.
        let segments = ParakeetTokenGrouping.groupIntoSegments([
            timing("First.", start: 0, end: 1),
            timing(" then", start: 1, end: 2),
            timing(" more", start: 2, end: 3),
        ])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "First.")
        XCTAssertEqual(segments[1].text, "then more")
    }

    func testGroupIntoSegmentsAllBlankTokensProducesNoSegments() {
        let segments = ParakeetTokenGrouping.groupIntoSegments([
            timing("   ", start: 0, end: 1),
            timing("\t", start: 1, end: 2),
        ])
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - makeSegment

    func testMakeSegmentEmptyTimingsReturnsNil() {
        XCTAssertNil(ParakeetTokenGrouping.makeSegment(from: []))
    }

    func testMakeSegmentAllWhitespaceTokensReturnsNil() {
        // After trimming the joined text is empty — should be rejected so
        // callers don't get a zero-content segment in the output.
        let result = ParakeetTokenGrouping.makeSegment(from: [
            timing("   ", start: 0, end: 1),
        ])
        XCTAssertNil(result)
    }

    func testMakeSegmentJoinsTokenTextVerbatim() {
        // Token boundaries are NOT decorated with whitespace by the helper —
        // the caller's tokens carry their own leading/trailing spaces (the
        // ASR tokenizer emits them). The helper just joins.
        let result = ParakeetTokenGrouping.makeSegment(from: [
            timing("Hello", start: 0, end: 1),
            timing(",", start: 1, end: 1.2),
            timing(" world", start: 1.2, end: 2),
        ])
        XCTAssertEqual(result?.text, "Hello, world")
    }

    // MARK: - Helpers

    private func timing(_ token: String, start: TimeInterval, end: TimeInterval) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1.0)
    }
}
