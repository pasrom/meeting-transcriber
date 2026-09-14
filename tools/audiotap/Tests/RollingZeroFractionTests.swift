@testable import AudioTapLib
import XCTest

/// The windowing behind both the digital-silence verdict and the delivery
/// credit. Tested apart from either so a failure points at the measurement
/// rather than at the decision it feeds.
final class RollingZeroFractionTests: XCTestCase {
    func testNothingObservedYieldsNoFraction() {
        let window = RollingZeroFraction(windowSeconds: 10)
        XCTAssertNil(window.zeroFraction)
        XCTAssertNil(window.span(now: 5))
    }

    func testEmptyBuffersAreIgnored() {
        var window = RollingZeroFraction(windowSeconds: 10)
        window.add(zeroSamples: 0, totalSamples: 0, now: 1)
        XCTAssertNil(window.zeroFraction)
    }

    func testFractionCountsSamplesNotBuffers() {
        var window = RollingZeroFraction(windowSeconds: 10)
        // One large mostly-zero buffer and one small fully-live buffer: by
        // buffer count this is 50% silent, by sample count 90%.
        window.add(zeroSamples: 900, totalSamples: 900, now: 1)
        window.add(zeroSamples: 0, totalSamples: 100, now: 2)
        XCTAssertEqual(window.zeroFraction ?? 0, 0.9, accuracy: 0.001)
    }

    func testPartialZerosWithinABufferAreCounted() {
        var window = RollingZeroFraction(windowSeconds: 10)
        window.add(zeroSamples: 800, totalSamples: 1000, now: 1)
        XCTAssertEqual(window.zeroFraction ?? 0, 0.8, accuracy: 0.001)
    }

    // MARK: - Rolling

    func testSamplesOlderThanTheWindowAreDropped() {
        var window = RollingZeroFraction(windowSeconds: 10)
        window.add(zeroSamples: 1000, totalSamples: 1000, now: 0)
        XCTAssertEqual(window.zeroFraction ?? 0, 1, accuracy: 0.001)
        // Far past the window: the old all-zero bin must no longer count.
        window.add(zeroSamples: 0, totalSamples: 1000, now: 100)
        XCTAssertEqual(window.zeroFraction ?? 1, 0, accuracy: 0.001)
    }

    func testSpanIsCappedAtTheWindow() {
        var window = RollingZeroFraction(windowSeconds: 10)
        window.add(zeroSamples: 1, totalSamples: 1, now: 0)
        XCTAssertEqual(window.span(now: 5) ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(window.span(now: 500) ?? 0, 10, accuracy: 0.001)
    }

    /// Memory must not grow with buffer rate — a two-minute window at
    /// production cadence would otherwise hold thousands of entries.
    func testMemoryIsBoundedByTheWindowNotTheBufferRate() {
        var window = RollingZeroFraction(windowSeconds: 10)
        var now: TimeInterval = 0
        while now < 600 {
            window.add(zeroSamples: 512, totalSamples: 1024, now: now)
            now += 0.002
        }
        // 10 s of one-second bins over a 500 Hz buffer rate: the count is a
        // function of the window, not of the 300,000 buffers observed.
        XCTAssertLessThanOrEqual(window.totalSamples, 1024 * 12 * 500)
        XCTAssertEqual(window.zeroFraction ?? 0, 0.5, accuracy: 0.01)
    }

    // MARK: - Reset

    func testResetDropsEverything() {
        var window = RollingZeroFraction(windowSeconds: 10)
        window.add(zeroSamples: 1000, totalSamples: 1000, now: 1)
        window.reset()
        XCTAssertNil(window.zeroFraction)
        XCTAssertNil(window.span(now: 2))
    }

    /// After a reset the span restarts, so a caller waiting for a full window
    /// waits again rather than acting on a sliver of the new anchor's audio.
    func testResetRestartsTheSpan() {
        var window = RollingZeroFraction(windowSeconds: 10)
        window.add(zeroSamples: 1, totalSamples: 1, now: 0)
        window.reset()
        window.add(zeroSamples: 1, totalSamples: 1, now: 100)
        XCTAssertEqual(window.span(now: 102) ?? 0, 2, accuracy: 0.001)
    }
}
