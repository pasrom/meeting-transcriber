@testable import AudioTapLib
import XCTest

/// The digital-silence verdict.
///
/// The fixtures here are shaped from measured recordings rather than invented:
/// a healthy tap's worst 120-second window is 41.7% exactly-zero samples, a
/// dead tap's best is 98.7%, and the dead ones are *not* uniformly zero — the
/// call that motivated the fractional criterion had 55 of 530 five-second
/// windows carrying some energy.
final class SilentTapWatchdogTests: XCTestCase {
    /// One 48 kHz stereo IOProc buffer's worth of samples, the granularity the
    /// production path feeds in at.
    private let bufferSamples = 1024

    /// Buffer cadence, near enough to production that the per-second sample
    /// floor is comfortably cleared.
    private let step: TimeInterval = 0.02

    /// Feed `seconds` of buffers whose samples are a `zeroFraction` share
    /// exactly zero.
    ///
    /// The zeros are spread across every buffer rather than bunched into whole
    /// silent buffers, which is the harder shape and the one the field data
    /// shows: a dead track's stray energy is scattered through it, so a
    /// criterion that only counts wholly-silent buffers reads such a track as
    /// less silent than it is.
    @discardableResult
    private func feed(
        _ watchdog: inout SilentTapWatchdog,
        zeroFraction: Double,
        seconds: TimeInterval,
        from start: TimeInterval,
    ) -> [SilentTapWatchdog.Action] {
        var actions: [SilentTapWatchdog.Action] = []
        var now = start
        let end = start + seconds
        let zeros = Int((Double(bufferSamples) * zeroFraction).rounded())
        while now <= end {
            if let action = watchdog.observe(
                zeroSamples: zeros, samples: bufferSamples, now: now,
            ) {
                actions.append(action)
            }
            now += step
        }
        return actions
    }

    // MARK: - The regression

    /// The incident shape, reproduced faithfully: a 44.7-minute track that is
    /// 1.9% nonzero samples overall, with the energy confined to 55 of its 530
    /// five-second windows and spread through those windows rather than
    /// filling them.
    ///
    /// This is the fixture that pins the per-sample counting. Inferring zeros
    /// from a buffer's summed squares would read this track as 1 - 55/530 =
    /// 89.6% zeros — just under the 90% threshold, and so no trip on the very
    /// recording the threshold was derived from.
    func testTripsOnTheIncidentShape() {
        var watchdog = SilentTapWatchdog()
        let windowSeconds = 5.0
        let liveWindowInterval = 530.0 / 55.0
        // Within a window that carries energy, this share of samples is still
        // zero: 1.9% nonzero overall concentrated into 10.4% of the duration.
        let zerosInLiveWindow = Int((Double(bufferSamples) * 0.82).rounded())

        var actions: [SilentTapWatchdog.Action] = []
        var now: TimeInterval = 0
        while now <= 150 {
            let windowIndex = (now / windowSeconds).rounded(.down)
            let isLiveWindow = windowIndex.truncatingRemainder(dividingBy: liveWindowInterval) < 1
            if let action = watchdog.observe(
                zeroSamples: isLiveWindow ? zerosInLiveWindow : bufferSamples,
                samples: bufferSamples,
                now: now,
            ) {
                actions.append(action)
            }
            now += step
        }
        XCTAssertEqual(
            actions, [.silenceDetected(mayRestart: true)],
            "the criterion must fire on the real dead-track shape, not just on uniform silence",
        )
    }

    /// The exact shape that defeated the unbroken-run criterion: a window that
    /// is 98% zeros with live buffers sprinkled through it. The old rule reset
    /// on every one of those and never fired across 45 minutes.
    func testTripsOnADeadTapWithStrayEnergyThroughout() {
        var watchdog = SilentTapWatchdog()
        let actions = feed(&watchdog, zeroFraction: 0.98, seconds: 150, from: 0)
        XCTAssertEqual(
            actions, [.silenceDetected(mayRestart: true)],
            "a 98% zero window must trip regardless of stray nonzero samples",
        )
        XCTAssertTrue(watchdog.isSilent)
    }

    /// The healthy ceiling measured across 20 recordings. Anything that fires
    /// here tears down a working tap.
    func testDoesNotTripAtTheHealthyCeiling() {
        var watchdog = SilentTapWatchdog()
        let actions = feed(&watchdog, zeroFraction: 0.417, seconds: 600, from: 0)
        XCTAssertTrue(actions.isEmpty, "41.7% zeros is normal idle behavior")
        XCTAssertFalse(watchdog.isSilent)
    }

    /// The dead floor. Both edges of the measured gap are pinned so a future
    /// revision cannot quietly move the threshold onto either population.
    func testTripsAtTheDeadFloor() {
        var watchdog = SilentTapWatchdog()
        let actions = feed(&watchdog, zeroFraction: 0.987, seconds: 150, from: 0)
        XCTAssertEqual(actions, [.silenceDetected(mayRestart: true)])
    }

    func testThresholdSitsInTheGapBetweenTheMeasuredPopulations() {
        XCTAssertGreaterThan(SilentTapWatchdog.defaultZeroFractionThreshold, 0.417)
        XCTAssertLessThan(SilentTapWatchdog.defaultZeroFractionThreshold, 0.987)
    }

    func testExactlyNinetyPercentTripsAtTheFullWindowBoundary() {
        var watchdog = SilentTapWatchdog()
        for second in 0 ..< 120 {
            XCTAssertNil(watchdog.observe(zeroSamples: 900, samples: 1000, now: Double(second)))
        }
        XCTAssertEqual(
            watchdog.observe(zeroSamples: 900, samples: 1000, now: 120),
            .silenceDetected(mayRestart: true),
        )
    }

    func testJustBelowNinetyPercentDoesNotTrip() {
        var watchdog = SilentTapWatchdog()
        for second in 0 ... 240 {
            XCTAssertNil(watchdog.observe(zeroSamples: 899, samples: 1000, now: Double(second)))
        }
        XCTAssertFalse(watchdog.isSilent)
    }

    /// The window length is what creates the separation: the healthy ceiling is
    /// essentially the longest idle run (49.85 s) divided by the window, so
    /// halving the window would lift it to ~83% and leave no gap at all.
    func testWindowIsLongEnoughToSeparateThePopulations() {
        let longestHealthyZeroRun = 49.85
        let ceiling = longestHealthyZeroRun / SilentTapWatchdog.defaultWindowSeconds
        XCTAssertLessThan(
            ceiling, SilentTapWatchdog.defaultZeroFractionThreshold - 0.4,
            "the window must keep the healthy ceiling well clear of the trip threshold",
        )
    }

    // MARK: - Fully silent taps

    func testTripsOnACompletelySilentTap() {
        var watchdog = SilentTapWatchdog()
        let actions = feed(&watchdog, zeroFraction: 1, seconds: 130, from: 0)
        XCTAssertEqual(actions, [.silenceDetected(mayRestart: true)])
    }

    func testDoesNotTripBeforeTheWindowIsFull() {
        var watchdog = SilentTapWatchdog()
        let actions = feed(&watchdog, zeroFraction: 1, seconds: 119, from: 0)
        XCTAssertTrue(
            actions.isEmpty,
            "a fraction over a partly-filled window is not comparable to the measured populations",
        )
    }

    func testAQuietButLiveTapNeverTrips() {
        var watchdog = SilentTapWatchdog()
        let actions = feed(&watchdog, zeroFraction: 0, seconds: 600, from: 0)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Recovery

    func testSustainedAudioAfterAnEpisodeReportsRecovery() {
        var watchdog = SilentTapWatchdog()
        feed(&watchdog, zeroFraction: 1, seconds: 130, from: 0)
        XCTAssertTrue(watchdog.isSilent)
        let actions = feed(&watchdog, zeroFraction: 0, seconds: 130, from: 130)
        XCTAssertEqual(actions, [.recovered])
        XCTAssertFalse(watchdog.isSilent)
    }

    /// Recovery is judged on the same rolling window, so one loud buffer inside
    /// an otherwise dead stretch must not clear the episode — that is precisely
    /// the stray energy the dead recordings are full of.
    func testAStrayBufferDoesNotClearAnEpisode() {
        var watchdog = SilentTapWatchdog()
        feed(&watchdog, zeroFraction: 1, seconds: 130, from: 0)
        let actions = feed(&watchdog, zeroFraction: 0.98, seconds: 130, from: 130)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(watchdog.isSilent)
    }

    func testRecoveryIsNotReportedWhenNoEpisodeWasOpen() {
        var watchdog = SilentTapWatchdog()
        let actions = feed(&watchdog, zeroFraction: 0, seconds: 130, from: 0)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Reporting once per episode

    func testTripIsReportedOncePerEpisodeNotPerWindow() {
        var watchdog = SilentTapWatchdog()
        // The incident's longer dead stretch was 33.5 minutes — sixteen
        // windows, which must still yield exactly one verdict.
        let actions = feed(&watchdog, zeroFraction: 0.98, seconds: 33.5 * 60, from: 0)
        XCTAssertEqual(actions, [.silenceDetected(mayRestart: true)])
    }

    // MARK: - Trigger budget

    func testBudgetBoundsHowManyEpisodesMoveTheAnchor() {
        var watchdog = SilentTapWatchdog(maxTriggers: 2)
        var clock: TimeInterval = 0
        var verdicts: [SilentTapWatchdog.Action] = []
        for _ in 0 ..< 3 {
            verdicts += feed(&watchdog, zeroFraction: 1, seconds: 130, from: clock)
            clock += 135
            verdicts += feed(&watchdog, zeroFraction: 0, seconds: 130, from: clock)
            clock += 135
        }
        XCTAssertEqual(verdicts, [
            .silenceDetected(mayRestart: true), .recovered,
            .silenceDetected(mayRestart: true), .recovered,
            .silenceDetected(mayRestart: false), .recovered,
        ])
    }

    /// An exhausted budget must not make the failure quieter — the user is
    /// still told, only the anchor move is withheld.
    func testExhaustedBudgetStillReportsSilence() {
        var watchdog = SilentTapWatchdog(maxTriggers: 0)
        let actions = feed(&watchdog, zeroFraction: 1, seconds: 130, from: 0)
        XCTAssertEqual(actions, [.silenceDetected(mayRestart: false)])
        XCTAssertTrue(watchdog.isSilent)
    }

    // MARK: - Teardown handoff

    func testResetWindowClearsTheMeasurementButKeepsTheLatch() {
        var watchdog = SilentTapWatchdog()
        feed(&watchdog, zeroFraction: 1, seconds: 130, from: 0)
        XCTAssertTrue(watchdog.isSilent)
        watchdog.resetWindow()
        XCTAssertTrue(watchdog.isSilent, "a move that did not help must still read as silent")
        let actions = feed(&watchdog, zeroFraction: 1, seconds: 119, from: 200)
        XCTAssertTrue(actions.isEmpty, "the new anchor's window must start empty")
    }

    // MARK: - Degenerate input

    func testEmptyBuffersAreIgnored() {
        var watchdog = SilentTapWatchdog()
        for tick in 0 ..< 200 {
            XCTAssertNil(watchdog.observe(zeroSamples: 0, samples: 0, now: Double(tick)))
        }
        XCTAssertFalse(watchdog.isSilent)
    }

    /// A tap that has all but stopped delivering is the level-staleness path's
    /// problem; producing a second verdict about the same failure here would
    /// only race it.
    func testTapDeliveringAlmostNothingDoesNotReachAVerdict() {
        var watchdog = SilentTapWatchdog()
        XCTAssertNil(watchdog.observe(zeroSamples: 64, samples: 64, now: 0))
        XCTAssertNil(watchdog.observe(zeroSamples: 64, samples: 64, now: 130))
        XCTAssertFalse(watchdog.isSilent)
    }
}
