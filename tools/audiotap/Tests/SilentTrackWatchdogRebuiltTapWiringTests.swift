@testable import AudioTapLib
import XCTest

/// The rebuilt-tap trial wired into a real `AppAudioCapture` (issue #672):
/// the deadline an installation arms, a tap torn down before it, and output
/// device changes during a rebuild. Built on the same stand-ins as
/// `SilentTrackWatchdogWiringTests`; a class of its own to keep that one under
/// the length limits.
@available(macOS 14.2, *)
final class SilentTrackWatchdogRebuiltTapWiringTests: XCTestCase {
    private typealias Rig = SilentTrackWatchdogWiringTests.Rig

    private let processes = [TappedProcess(pid: 1, audioObjectID: 11)]
    private let recovery = SilentTrackWatchdogPolicy.recoveryWindowSeconds

    private func makeRig() -> Rig {
        Rig.make()
    }

    /// Started; the caller stops it.
    private func startedRig() throws -> Rig {
        let rig = makeRig()
        try rig.capture.start()
        XCTAssertEqual(rig.attempts.starts, 1, "precondition: start() ran one attempt")
        return rig
    }

    /// Let queued main-queue work run.
    private func settle(_ seconds: TimeInterval) {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 5)
    }

    private var deadline: TimeInterval {
        SilentTrackWatchdogPolicy.rebuiltTapDeadlineSeconds
    }

    /// Trigger one rebuild and wait for its tap to be installed.
    private func rebuild(_ rig: Rig) {
        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.3)
    }

    /// The rebuild's tap is installed and no tick ever judges it (the #693
    /// failure delivers no buffer at all). The deadline its installation
    /// armed closes it, and nothing is rebuilt on the strength of that alone.
    func testARebuiltTapNoTickJudgesIsClosedByItsDeadline() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        rebuild(rig)

        let armed = try XCTUnwrap(rig.deadlines.pending(at: deadline).first, "installing the rebuilt tap armed it")
        armed.perform()

        let counters = rig.capture.silentTrackDiagnostics.watchdogCounters
        XCTAssertEqual(counters?.rebuiltTapStalled, 1)
        XCTAssertEqual(rig.attempts.starts, 2, "the verdict alone rebuilds nothing")
        let summary = try XCTUnwrap(rig.capture.silentTrackWatchdogSummary)
        XCTAssertTrue(summary.contains("watchdogRebuiltTapStalled=1"), "the stop summary carries it")
    }

    /// A tick judged the rebuild first, so its deadline has nothing to close.
    func testARebuildATickJudgedLeavesItsDeadlineNothing() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        rebuild(rig)
        let armed = try XCTUnwrap(rig.deadlines.pending(at: deadline).first, "precondition: a deadline was armed")

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 200), now: 1000 + recovery, processes: processes)
        armed.perform()

        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuiltTapStalled, 0)
    }

    /// The recording's own first tap is not a rebuild and arms nothing.
    func testTheFirstTapArmsNoDeadline() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        settle(0.3)

        XCTAssertTrue(rig.deadlines.pending(at: deadline).isEmpty)
    }

    /// The deadline belongs to an installed tap, not to the rebuild: a rebuild
    /// whose restart never installs one arms nothing, and the restart's
    /// give-up keeps the verdict.
    func testARebuildWhoseRestartNeverInstallsArmsNoDeadline() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        let fastRetry: @Sendable (Int) -> CaptureRestartRetryAction = { attemptsSoFar in
            attemptsSoFar < 1 ? .retry(afterSeconds: 0.05) : .giveUp
        }
        rig.capture.deviceChangeCoordinator = OutputDeviceChangeCoordinator(
            initialRestartDelay: 0.05, decideRetry: fastRetry,
        )
        let gaveUp = expectation(description: "the restart gave up")
        rig.capture.onGiveUp = { gaveUp.fulfill() }
        rig.attempts.fail = true

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        wait(for: [gaveUp], timeout: 10)

        XCTAssertTrue(rig.deadlines.pending(at: deadline).isEmpty)
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.endedChannel, true)
    }

    /// The restart before the installation took longer than the whole
    /// recovery window, as a backed-off retry can. The window runs from the
    /// installation, so signal right after it is still credited.
    func testARebuildWhoseRestartTookLongIsJudgedFromItsInstallation() throws {
        let rig = makeRig()
        // Slow enough to move the clock before the attempt runs.
        rig.capture.deviceChangeCoordinator = OutputDeviceChangeCoordinator(initialRestartDelay: 2.0)
        try rig.capture.start()
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        // The rebuild stamps its start on the clock first; only then does
        // the clock move on, ahead of the attempt.
        waitForRebuildStart(rig)
        rig.clock.now = 1000 + recovery + 5
        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.3)
        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 1), now: 1000 + recovery + 8, processes: processes)

        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.recoveries, 1)
    }

    /// A device change during an open rebuild: the restart it starts builds
    /// a tap whose signal is not the rebuild's, so the verdict is withheld.
    func testADeviceChangeDuringARebuildWithholdsItsVerdict() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        rebuild(rig)

        rig.capture.handleOutputDeviceChanged()
        wait(for: [rig.attempts.expectation(reaching: 3)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.3)
        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 1), now: 1005, processes: processes)

        let counters = rig.capture.silentTrackDiagnostics.watchdogCounters
        XCTAssertEqual(counters?.superseded, 1)
        XCTAssertEqual(counters?.recoveries, 0)
    }

    /// A device change that lands while the rebuild's restart has capture
    /// stopped is dropped by the restart path, yet the rebuild's tap is then
    /// built on the new device. Its verdict is withheld all the same.
    func testADeviceChangeTheRestartPathDropsStillWithholdsTheVerdict() throws {
        let rig = makeRig()
        rig.capture.deviceChangeCoordinator = OutputDeviceChangeCoordinator(initialRestartDelay: 2.0)
        try rig.capture.start()
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        waitForRebuildStart(rig)
        XCTAssertFalse(rig.capture.isRunning, "precondition: the restart has capture stopped")
        rig.capture.handleOutputDeviceChanged()
        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.3)
        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 1), now: 1005, processes: processes)

        let counters = rig.capture.silentTrackDiagnostics.watchdogCounters
        XCTAssertEqual(counters?.superseded, 1)
        XCTAssertEqual(counters?.recoveries, 0)
    }

    /// A rate-zero tap is installed, which arms its deadline, then torn down
    /// for a retry, and the retry throws. The deadline firing in between
    /// finds no tap to judge, and the give-up is recorded as ending the
    /// channel rather than lost behind a rebuild already closed.
    func testATornDownRateZeroTapsDeadlineClosesNothing() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        let retry: @Sendable (Int) -> CaptureRestartRetryAction = { attemptsSoFar in
            attemptsSoFar < 1 ? .retry(afterSeconds: 1.0) : .giveUp
        }
        rig.capture.deviceChangeCoordinator = OutputDeviceChangeCoordinator(
            initialRestartDelay: 0.05, decideRetry: retry,
        )
        let gaveUp = expectation(description: "the restart gave up")
        rig.capture.onGiveUp = { gaveUp.fulfill() }
        rig.attempts.zeroRateOnce = true

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.2)
        rig.attempts.fail = true
        XCTAssertFalse(rig.capture.isRunning, "precondition: the rate-zero tap was torn down for the retry")
        let armed = try XCTUnwrap(rig.deadlines.pending(at: deadline).first, "precondition: its install armed one")
        armed.perform()
        wait(for: [gaveUp], timeout: 10)

        let counters = rig.capture.silentTrackDiagnostics.watchdogCounters
        XCTAssertEqual(counters?.rebuiltTapStalled, 0)
        XCTAssertEqual(counters?.endedChannel, true)
    }

    /// Polled tightly on the main run loop, where the rebuild starts: a
    /// predicate expectation polls about once a second, slower than the
    /// restart's wait.
    private func waitForRebuildStart(_ rig: Rig) {
        let giveUpAt = Date().addingTimeInterval(2)
        while rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuilds != 1, Date() < giveUpAt {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(rig.attempts.starts, 1, "precondition: the rebuild started before its attempt")
    }
}
