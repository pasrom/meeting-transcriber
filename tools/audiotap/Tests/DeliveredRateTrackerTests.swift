@testable import AudioTapLib
import XCTest

/// `DeliveredRateTracker` decides when the published capture rate disagrees with
/// the rate the IOProc is actually delivering (issue #673). Pure arithmetic over
/// the two numbers every buffer already carries, so the bulk of the assertions
/// live here rather than on the write path.
final class DeliveredRateTrackerTests: XCTestCase {
    /// Drive `count` buffers of `frames` spaced `period` apart, returning every
    /// rate the tracker confirmed along the way. `current` follows a confirmed
    /// rate the way the production caller publishes it.
    private func run(
        _ tracker: inout DeliveredRateTracker,
        frames: Int,
        period: Double,
        count: Int,
        current: inout Int,
        from start: Double = 0,
    ) -> [Int] {
        var confirmed: [Int] = []
        for index in 0 ..< count {
            if let rate = tracker.observe(
                frames: frames, hostSeconds: start + Double(index) * period, current: current,
            ) {
                confirmed.append(rate)
                current = rate
            }
        }
        return confirmed
    }

    // MARK: - The two directions

    func testAHalvedDeliveredRateIsConfirmed() {
        var tracker = DeliveredRateTracker()
        var current = 48000
        // 1 s of buffers that agree with the published rate.
        XCTAssertEqual(run(&tracker, frames: 480, period: 0.01, count: 100, current: &current), [])
        // Then the same buffers at half the cadence: 24 kHz delivered.
        let confirmed = run(
            &tracker, frames: 480, period: 0.02, count: 150, current: &current, from: 1.0,
        )
        XCTAssertEqual(confirmed, [24000], "confirmed once, then left alone")
    }

    func testADoubledDeliveredRateIsConfirmed() {
        var tracker = DeliveredRateTracker()
        var current = 24000
        XCTAssertEqual(run(&tracker, frames: 480, period: 0.02, count: 50, current: &current), [])
        let confirmed = run(
            &tracker, frames: 480, period: 0.01, count: 300, current: &current, from: 1.0,
        )
        XCTAssertEqual(confirmed, [48000])
    }

    func testItTakesAboutTwoWindowsToConfirm() throws {
        var tracker = DeliveredRateTracker()
        var firstAt: Double?
        // 24 kHz delivered against a 48 kHz publication from the first buffer,
        // so the latency measured here is the detector's own, with no
        // straddling window in front of it.
        for index in 0 ..< 300 where firstAt == nil {
            let stamp = Double(index) * 0.02
            if tracker.observe(frames: 480, hostSeconds: stamp, current: 48000) != nil {
                firstAt = stamp
            }
        }
        let latency = try XCTUnwrap(firstAt, "the change must be found at all")
        XCTAssertLessThanOrEqual(
            latency, 1.5, "two 0.5 s windows plus the one in flight when the change landed",
        )
    }

    // MARK: - What must not happen

    func testASteadyRateIsNeverRepublished() {
        var tracker = DeliveredRateTracker()
        var current = 48000
        XCTAssertEqual(
            run(&tracker, frames: 480, period: 0.01, count: 1000, current: &current), [],
            "10 s at the published rate must not touch the converter",
        )
    }

    func testClockJitterDoesNotChurnTheRate() {
        var tracker = DeliveredRateTracker()
        var confirmed: [Int] = []
        // Every period 2 % off nominal, alternating either way: the shape of
        // ordinary callback jitter, and well past CoreAudio's own clock drift
        // of a few parts per million. Over a window the total is unchanged, and
        // no single gap stands out from the average.
        var stamp = 0.0
        for index in 0 ..< 1000 {
            if let rate = tracker.observe(frames: 480, hostSeconds: stamp, current: 48000) {
                confirmed.append(rate)
            }
            stamp += 0.01 * (index.isMultiple(of: 2) ? 1.02 : 0.98)
        }
        XCTAssertEqual(confirmed, [])
    }

    /// The frame count alone cannot tell a device delivering fewer frames from
    /// one delivering the same frames with some callbacks dropped. Both look
    /// like a lower rate. What separates them is the shape of the gaps.
    func testASteadyLossOfCallbacksIsNotMistakenForARateChange() {
        var tracker = DeliveredRateTracker()
        var confirmed: [Int] = []
        // A real 48 kHz stream losing one callback in twelve. Each surviving
        // window totals about 46 x 480 frames over 0.5 s, which is 44160 Hz,
        // within 0.14 % of 44100 and therefore adoptable on the frame count
        // alone. Two such windows in a row would publish 44100 and play the
        // rest of the recording 8.8 % slow.
        for index in 0 ..< 600 where !index.isMultiple(of: 12) {
            if let rate = tracker.observe(
                frames: 480, hostSeconds: Double(index) * 0.01, current: 48000,
            ) {
                confirmed.append(rate)
            }
        }
        XCTAssertEqual(confirmed, [], "dropped callbacks are not a rate change")
    }

    /// And the guard must not block the thing it sits in front of: a real
    /// change moves every gap together, so nothing stands out.
    func testAUniformChangeIsStillAdoptedThroughTheGapGuard() {
        var tracker = DeliveredRateTracker()
        var current = 48000
        _ = run(&tracker, frames: 480, period: 0.01, count: 100, current: &current)
        let confirmed = run(
            &tracker, frames: 480, period: 0.02, count: 200, current: &current, from: 1.0,
        )
        XCTAssertEqual(confirmed, [24000])
    }

    /// The reason confirmation exists. A window that straddles a 48 to 24 kHz
    /// switch can measure a rate that snaps cleanly onto a *different* standard
    /// rate, and a single-window rule would adopt it.
    func testAWindowStraddlingTheChangeIsNotAdopted() {
        var tracker = DeliveredRateTracker()
        var current = 48000
        // Switch cadence 84 % of the way into the second window: it measures
        // 44160 Hz, which is within 0.14 % of 44100.
        var confirmed = run(&tracker, frames: 480, period: 0.01, count: 42, current: &current)
        confirmed += run(
            &tracker, frames: 480, period: 0.02, count: 60, current: &current, from: 0.42,
        )
        XCTAssertEqual(
            confirmed, [24000],
            "44100 must never reach the converter, and the real rate must still be found",
        )
    }

    func testARestartGapDiscardsTheWindowInsteadOfMeasuringIt() {
        var tracker = DeliveredRateTracker()
        var current = 48000
        var confirmed = run(&tracker, frames: 480, period: 0.01, count: 20, current: &current)
        // A 4 s hole, longer than any window worth trusting: those 20 buffers
        // spread over 4 s would measure as 2400 Hz.
        confirmed += run(
            &tracker, frames: 480, period: 0.01, count: 200, current: &current, from: 4.2,
        )
        XCTAssertEqual(confirmed, [], "the gap is a restart, not a rate change")
    }

    func testAPublishedRateChangingUnderTheTrackerDiscardsTheWindow() {
        var tracker = DeliveredRateTracker()
        // Half a window measured against 48000 ...
        var stale = 48000
        _ = run(&tracker, frames: 480, period: 0.01, count: 40, current: &stale)
        // ... then the restart adoption publishes 24000 and the delivered rate
        // agrees with it. Nothing may be confirmed off the mixed window.
        var adopted = 24000
        let confirmed = run(
            &tracker, frames: 480, period: 0.02, count: 200, current: &adopted, from: 0.4,
        )
        XCTAssertEqual(confirmed, [])
    }

    func testDegenerateInputIsIgnored() {
        var tracker = DeliveredRateTracker()
        XCTAssertNil(tracker.observe(frames: 0, hostSeconds: 0, current: 48000))
        XCTAssertNil(tracker.observe(frames: 480, hostSeconds: .nan, current: 48000))
        XCTAssertNil(tracker.observe(frames: 480, hostSeconds: .infinity, current: 48000))
        // Stamps going backwards (a wrapped or corrupt clock) reopen the window
        // rather than measuring a negative span.
        _ = tracker.observe(frames: 480, hostSeconds: 10.0, current: 48000)
        XCTAssertNil(tracker.observe(frames: 480, hostSeconds: 9.0, current: 48000))
    }

    /// An unknown published rate (nothing resolved yet) must be fillable, since
    /// the first-callback correction may never run on a session that starts
    /// mid-change.
    func testAnUnknownPublishedRateIsFilledIn() {
        var tracker = DeliveredRateTracker()
        var current = 0
        let confirmed = run(&tracker, frames: 480, period: 0.01, count: 200, current: &current)
        XCTAssertEqual(confirmed, [48000])
    }
}
