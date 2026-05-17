@testable import MeetingTranscriber
import XCTest

final class ChannelHealthMonitorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMonitor(debounce: TimeInterval = 90) -> ChannelHealthMonitor {
        ChannelHealthMonitor(
            silenceThresholdDBFS: -60,
            speechThresholdDBFS: -50,
            debounceSeconds: debounce,
        )
    }

    // MARK: - Healthy / idle states

    func testBothQuietProducesNoEvent() {
        var monitor = makeMonitor()
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(120)))
    }

    func testBothSpeakingProducesNoEvent() {
        var monitor = makeMonitor()
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -25, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -25, now: t0.addingTimeInterval(120)))
    }

    func testAmbiguousMidRangeProducesNoEvent() {
        // Between thresholds: not "silent" and not "speech" — treat as undecided.
        var monitor = makeMonitor()
        XCTAssertNil(monitor.update(micDBFS: -55, appDBFS: -55, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -55, appDBFS: -55, now: t0.addingTimeInterval(120)))
    }

    // MARK: - Asymmetric silence detection (debounce + latch)

    func testAsymmetricSilenceBelowDebounceProducesNoEvent() {
        var monitor = makeMonitor(debounce: 90)
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -80, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(89)))
    }

    func testAsymmetricSilenceAtDebounceFiresStarted() {
        var monitor = makeMonitor(debounce: 90)
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -80, now: t0))
        let event = monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(90))
        XCTAssertEqual(event, .started(channel: .app, quietSince: t0))
    }

    func testStartedFiresOnlyOncePerEpisode() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(5))
        // Subsequent updates while still in the same episode must NOT re-fire.
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(6)))
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(30)))
    }

    // MARK: - Recovery

    func testRecoveryAfterStartedFiresRecovered() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(5))
        // App channel returns above speech threshold.
        let event = monitor.update(micDBFS: -30, appDBFS: -25, now: t0.addingTimeInterval(8))
        XCTAssertEqual(event, .recovered(channel: .app))
    }

    func testRecoveryBeforeDebounceProducesNoEvent() {
        var monitor = makeMonitor(debounce: 90)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0)
        // App recovers BEFORE the debounce elapsed → no .started, no .recovered.
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -25, now: t0.addingTimeInterval(20)))
    }

    func testRecoveryClearsLatchSoNextEpisodeCanFireAgain() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(5)) // .started
        _ = monitor.update(micDBFS: -30, appDBFS: -25, now: t0.addingTimeInterval(8)) // .recovered

        // Channel dies again — must produce a fresh .started after another full debounce.
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(10)))
        let event = monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(15))
        XCTAssertEqual(event, .started(channel: .app, quietSince: t0.addingTimeInterval(10)))
    }

    // MARK: - Symmetry (mic-dead case)

    func testMicDeadAppSpeakingFiresStartedForMic() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -80, appDBFS: -30, now: t0)
        let event = monitor.update(micDBFS: -80, appDBFS: -30, now: t0.addingTimeInterval(5))
        XCTAssertEqual(event, .started(channel: .mic, quietSince: t0))
    }

    // MARK: - Channel switch (rare but real: e.g. mic disconnects after app dies)

    func testChannelSwitchAfterStartedFiresRecoveredForOldChannel() {
        // mic episode latches first, then mic recovers + app dies in the same tick.
        // The monitor must surface `.recovered(channel: .mic)` so AppState can
        // clear the stale flag before app eventually debounces out on its own.
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -80, appDBFS: -25, now: t0)
        _ = monitor.update(micDBFS: -80, appDBFS: -25, now: t0.addingTimeInterval(5)) // mic .started
        let event = monitor.update(micDBFS: -25, appDBFS: -80, now: t0.addingTimeInterval(7))
        XCTAssertEqual(event, .recovered(channel: .mic))
    }

    func testChannelSwitchMidEpisodeResetsTracking() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0) // start tracking app
        // Roles swap before app debounce elapses.
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -30, now: t0.addingTimeInterval(3)))
        // Mic must accumulate its own full debounce from this point.
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -30, now: t0.addingTimeInterval(6)))
        let event = monitor.update(micDBFS: -80, appDBFS: -30, now: t0.addingTimeInterval(8))
        XCTAssertEqual(event, .started(channel: .mic, quietSince: t0.addingTimeInterval(3)))
    }

    // MARK: - reset()

    func testResetClearsActiveEpisode() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(5)) // .started
        monitor.reset()

        // Same conditions must be able to fire a fresh .started after another full debounce.
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(10)))
        let event = monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(15))
        XCTAssertEqual(event, .started(channel: .app, quietSince: t0.addingTimeInterval(10)))
    }

    func testResetWhileTrackingButBeforeStartedClearsTracking() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -30, appDBFS: -80, now: t0) // tracking app, not yet started
        monitor.reset()
        // Under reset-clears semantics, the +6 update starts fresh tracking.
        // Under "reset only clears latch" semantics, this would fire .started (6 ≥ 5 since t0).
        XCTAssertNil(monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(6)))
        // Confirm fresh tracking by checking quietSince == +6 (not t0).
        let event = monitor.update(micDBFS: -30, appDBFS: -80, now: t0.addingTimeInterval(11))
        XCTAssertEqual(event, .started(channel: .app, quietSince: t0.addingTimeInterval(6)))
    }

    // MARK: - Custom thresholds

    func testCustomThresholdsAreHonored() {
        var monitor = ChannelHealthMonitor(
            silenceThresholdDBFS: -70,
            speechThresholdDBFS: -40,
            debounceSeconds: 1,
        )
        // -65 is silent under default thresholds (-60) but ABOVE -70 here → not silent.
        XCTAssertNil(monitor.update(micDBFS: -35, appDBFS: -65, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -35, appDBFS: -65, now: t0.addingTimeInterval(5)))
    }
}
