@testable import MeetingTranscriber
import XCTest

final class UtteranceRingBufferTests: XCTestCase {
    // Sample rate is fixed at 16 kHz internally: 1 ms == 16 samples.
    private let samplesPerMs = 16

    /// Builds a ramp of `count` samples where sample i == Float(start + i).
    /// Distinct, recognizable values let assertions catch off-by-one index math.
    private func ramp(start: Int, count: Int) -> [Float] {
        (0 ..< count).map { Float(start + $0) }
    }

    // MARK: - Basic append + extract

    func testSimpleAppendAndExtract() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        // Append 100 ms == 1600 samples, values 0..<1600.
        buffer.append(ramp(start: 0, count: 100 * samplesPerMs))
        // Extract [10 ms, 30 ms) -> samples [160, 480) -> values 160..<480.
        let out = buffer.extract(fromMs: 10, toMs: 30)
        XCTAssertEqual(out, ramp(start: 160, count: 20 * samplesPerMs))
    }

    func testExtractFromZeroToEnd() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append(ramp(start: 0, count: 50 * samplesPerMs)) // 50 ms
        let out = buffer.extract(fromMs: 0, toMs: 50)
        XCTAssertEqual(out, ramp(start: 0, count: 50 * samplesPerMs))
    }

    func testAdjacentExtractsAreContiguousAndNonOverlapping() {
        // The half-open [fromMs, toMs) contract: back-to-back utterances
        // extracted with shared boundary ms must neither overlap nor gap.
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append(ramp(start: 0, count: 20 * samplesPerMs)) // ms 0..<20
        let first = buffer.extract(fromMs: 0, toMs: 10)
        let second = buffer.extract(fromMs: 10, toMs: 20)
        XCTAssertEqual(first, ramp(start: 0, count: 10 * samplesPerMs))
        XCTAssertEqual(second, ramp(start: 10 * samplesPerMs, count: 10 * samplesPerMs))
        XCTAssertEqual(first + second, ramp(start: 0, count: 20 * samplesPerMs))
    }

    func testMultipleAppendsAreContiguous() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append(ramp(start: 0, count: 20 * samplesPerMs)) // ms 0..<20
        buffer.append(ramp(start: 20 * samplesPerMs, count: 20 * samplesPerMs)) // ms 20..<40
        // Extract across the append boundary [15 ms, 25 ms).
        let out = buffer.extract(fromMs: 15, toMs: 25)
        XCTAssertEqual(out, ramp(start: 15 * samplesPerMs, count: 10 * samplesPerMs))
    }

    // MARK: - Wrap-around (overflow drops oldest samples)

    func testExtractAcrossWrapAroundReturnsCorrectValues() {
        // Tiny capacity so we exercise overflow with verifiable values.
        // Capacity 320 samples == 20 ms.
        var buffer = UtteranceRingBuffer(capacitySamples: 320)
        // Append 30 ms == 480 samples, values 0..<480.
        buffer.append(ramp(start: 0, count: 30 * samplesPerMs))
        // Only the last 320 samples survive: absolute indices [160, 480) -> values 160..<480.
        // That maps to ms range [10 ms, 30 ms).
        let out = buffer.extract(fromMs: 10, toMs: 30)
        XCTAssertEqual(out, ramp(start: 160, count: 320))
    }

    func testWrapAroundAcrossManyAppends() {
        var buffer = UtteranceRingBuffer(capacitySamples: 320) // 20 ms
        // Three 10 ms appends -> 480 samples total, values 0..<480.
        buffer.append(ramp(start: 0, count: 10 * samplesPerMs))
        buffer.append(ramp(start: 10 * samplesPerMs, count: 10 * samplesPerMs))
        buffer.append(ramp(start: 20 * samplesPerMs, count: 10 * samplesPerMs))
        // Last 320 samples == values 160..<480 == ms [10, 30).
        let out = buffer.extract(fromMs: 10, toMs: 30)
        XCTAssertEqual(out, ramp(start: 160, count: 320))
    }

    // MARK: - Clamping (partially scrolled out)

    func testRangePartiallyScrolledOutReturnsBufferedSuffix() {
        var buffer = UtteranceRingBuffer(capacitySamples: 320) // 20 ms
        buffer.append(ramp(start: 0, count: 30 * samplesPerMs)) // 30 ms, last 20 ms buffered
        // Ask for [5 ms, 25 ms): absolute samples [80, 400).
        // Only [160, 400) is still buffered (oldest retained index == 160).
        // Expect values 160..<400.
        let out = buffer.extract(fromMs: 5, toMs: 25)
        XCTAssertEqual(out, ramp(start: 160, count: 400 - 160))
    }

    func testFullyScrolledOutRangeReturnsEmpty() {
        var buffer = UtteranceRingBuffer(capacitySamples: 320) // 20 ms
        buffer.append(ramp(start: 0, count: 30 * samplesPerMs)) // 30 ms, only [160,480) buffered
        // Ask for [0 ms, 10 ms): absolute samples [0, 160), all scrolled out.
        let out = buffer.extract(fromMs: 0, toMs: 10)
        XCTAssertEqual(out, [])
    }

    // MARK: - toMs beyond appended

    func testToMsBeyondAppendedClampsToEnd() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append(ramp(start: 0, count: 40 * samplesPerMs)) // 40 ms total
        // Ask for [30 ms, 100 ms): only [30 ms, 40 ms) exists.
        let out = buffer.extract(fromMs: 30, toMs: 100)
        XCTAssertEqual(out, ramp(start: 30 * samplesPerMs, count: 10 * samplesPerMs))
    }

    func testFromMsBeyondAppendedReturnsEmpty() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append(ramp(start: 0, count: 40 * samplesPerMs)) // 40 ms total
        // Ask starting past the end entirely.
        let out = buffer.extract(fromMs: 50, toMs: 60)
        XCTAssertEqual(out, [])
    }

    // MARK: - Inverted / empty ranges

    func testInvertedRangeReturnsEmpty() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append(ramp(start: 0, count: 50 * samplesPerMs))
        XCTAssertEqual(buffer.extract(fromMs: 30, toMs: 10), [])
    }

    func testEmptyRangeReturnsEmpty() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append(ramp(start: 0, count: 50 * samplesPerMs))
        XCTAssertEqual(buffer.extract(fromMs: 20, toMs: 20), [])
    }

    func testNegativeFromMsClampsToZero() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append(ramp(start: 0, count: 20 * samplesPerMs)) // 20 ms
        // Negative fromMs should clamp to sample 0.
        let out = buffer.extract(fromMs: -5, toMs: 10)
        XCTAssertEqual(out, ramp(start: 0, count: 10 * samplesPerMs))
    }

    // MARK: - Empty buffer

    func testExtractOnEmptyBufferReturnsEmpty() {
        let buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        XCTAssertEqual(buffer.extract(fromMs: 0, toMs: 10), [])
    }

    func testAppendingEmptyArrayIsNoOp() {
        var buffer = UtteranceRingBuffer(capacitySamples: 480_000)
        buffer.append([])
        XCTAssertEqual(buffer.extract(fromMs: 0, toMs: 10), [])
        buffer.append(ramp(start: 0, count: 10 * samplesPerMs))
        buffer.append([])
        XCTAssertEqual(buffer.extract(fromMs: 0, toMs: 10), ramp(start: 0, count: 10 * samplesPerMs))
    }
}
