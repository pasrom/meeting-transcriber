@testable import MeetingTranscriber
import XCTest

final class SilentRecordingMonitorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMonitor(debounce: TimeInterval = 60) -> SilentRecordingMonitor {
        SilentRecordingMonitor(
            silenceThresholdDBFS: -60,
            speechThresholdDBFS: -50,
            debounceSeconds: debounce,
        )
    }

    // MARK: - Healthy states never fire

    func testActiveRecordingProducesNoEvent() {
        var monitor = makeMonitor()
        XCTAssertNil(monitor.update(micDBFS: -25, appDBFS: -30, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -25, appDBFS: -30, now: t0.addingTimeInterval(120)))
    }

    func testAsymmetricSilenceProducesNoEvent() {
        // mic dead while app speaks (or vice versa) is the channel-health
        // monitor's job — this monitor should ignore it.
        var monitor = makeMonitor()
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -25, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -25, now: t0.addingTimeInterval(120)))
        XCTAssertNil(monitor.update(micDBFS: -25, appDBFS: -80, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -25, appDBFS: -80, now: t0.addingTimeInterval(120)))
    }

    func testAmbiguousMidRangeProducesNoEvent() {
        // Mid-zone between silence and speech thresholds isn't silent —
        // some signal is present even if not loud speech.
        var monitor = makeMonitor()
        XCTAssertNil(monitor.update(micDBFS: -55, appDBFS: -55, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -55, appDBFS: -55, now: t0.addingTimeInterval(120)))
    }

    // MARK: - Silent-recording detection (debounce + latch)

    func testBothSilentBelowDebounceProducesNoEvent() {
        var monitor = makeMonitor(debounce: 60)
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0))
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(59)))
    }

    func testBothSilentAtDebounceFiresStarted() {
        var monitor = makeMonitor(debounce: 60)
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0))
        let event = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(60))
        XCTAssertEqual(event, .started(silenceSince: t0))
    }

    func testStartedFiresOnlyOncePerEpisode() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(5))
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(6)))
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(30)))
    }

    // MARK: - Recovery

    func testRecoveryAfterStartedWhenMicReturnsToSpeech() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(5))
        let event = monitor.update(micDBFS: -25, appDBFS: -80, now: t0.addingTimeInterval(8))
        XCTAssertEqual(event, .recovered)
    }

    func testRecoveryAfterStartedWhenAppReturnsToSpeech() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(5))
        let event = monitor.update(micDBFS: -80, appDBFS: -25, now: t0.addingTimeInterval(8))
        XCTAssertEqual(event, .recovered)
    }

    func testRecoveryBeforeDebounceProducesNoEvent() {
        var monitor = makeMonitor(debounce: 60)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        XCTAssertNil(monitor.update(micDBFS: -25, appDBFS: -80, now: t0.addingTimeInterval(20)))
    }

    func testRecoveryClearsLatchSoNextEpisodeCanFire() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(5))
        _ = monitor.update(micDBFS: -25, appDBFS: -25, now: t0.addingTimeInterval(8))
        // Both go silent again — must produce a fresh .started after another full debounce.
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(10)))
        let event = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(15))
        XCTAssertEqual(event, .started(silenceSince: t0.addingTimeInterval(10)))
    }

    // MARK: - Hysteresis (transient mid-zone reads keep timer running)

    func testTransientAmbiguousReadDoesNotResetTimer() {
        // Mirrors the same hysteresis principle as ChannelHealthMonitor: a single
        // ambiguous read mid-debounce on one side shouldn't reset the both-silent
        // timer (an audio glitch or borderline noise spike on one channel doesn't
        // mean the recording stopped being silent).
        var monitor = makeMonitor(debounce: 30)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -55, appDBFS: -80, now: t0.addingTimeInterval(15))
        let event = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(30))
        XCTAssertEqual(event, .started(silenceSince: t0))
    }

    func testActualSpeechResetsTimer() {
        // Genuine speech on either side proves the recording isn't silent —
        // discard any in-flight episode so the next silent stretch debounces
        // fresh (the original t0 quietSince is gone; the second-stretch
        // .started carries the +30s quietSince, not t0).
        var monitor = makeMonitor(debounce: 30)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -25, appDBFS: -80, now: t0.addingTimeInterval(15))
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(30)))
        let event = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(60))
        XCTAssertEqual(event, .started(silenceSince: t0.addingTimeInterval(30)))
    }

    // MARK: - reset()

    func testResetClearsActiveEpisode() {
        var monitor = makeMonitor(debounce: 5)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(5))
        monitor.reset()
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(10)))
        let event = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(15))
        XCTAssertEqual(event, .started(silenceSince: t0.addingTimeInterval(10)))
    }

    // MARK: - Custom threshold

    func testCustomDebounceHonored() {
        var monitor = makeMonitor(debounce: 10)
        _ = monitor.update(micDBFS: -80, appDBFS: -80, now: t0)
        XCTAssertNil(monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(9)))
        let event = monitor.update(micDBFS: -80, appDBFS: -80, now: t0.addingTimeInterval(10))
        XCTAssertEqual(event, .started(silenceSince: t0))
    }
}
