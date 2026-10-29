@testable import AudioTapLib
import CoreAudio
import XCTest

/// The no-first-buffer trigger wired into a real `AppAudioCapture` (issue
/// #693): the probe `startCapture` arms reads the tapped processes, a process
/// rendering while nothing has arrived becomes a rebuild through the same
/// coordinator, arbiter and attempt the device-change restart uses, and with
/// the watchdog off the probe only logs, as it did before. The hardware is
/// replaced at the seams `SilentTrackWatchdogWiringTests` uses, through its
/// `Rig`; the probe itself is armed by hand, since the attempt seam replaces
/// the `startCapture` that arms it in production, and fired by hand, since a
/// five-second sleep would prove nothing on a loaded machine.
@available(macOS 14.2, *)
final class SilentTrackWatchdogNoFirstBufferWiringTests: XCTestCase {
    private typealias Rig = SilentTrackWatchdogWiringTests.Rig

    private let processes = [TappedProcess(pid: 1, audioObjectID: 11)]

    /// A started capture whose track never delivered, with one probe armed
    /// at the production schedule's first offset. The caller stops it.
    private func startedRig(watchdog: Bool = true, running: Bool = true) throws -> Rig {
        // Typed local, not a trailing closure: the rig's last parameter is its
        // sink, and a trailing closure would bind to that one.
        let never: @Sendable () -> ChannelSignalAges = { .unknown }
        let rig = try Rig.started(watchdog: watchdog, running: running, readAges: never)
        rig.capture.armNoBufferProbes(processes, aggregateID: 8, schedule: .init(offsets: [5]))
        return rig
    }

    private func fireProbe(_ rig: Rig) throws {
        let probe = try XCTUnwrap(rig.deadlines.pending(at: 5).first, "the 5 s probe is armed")
        probe.perform()
    }

    func testAProbeWithAProcessRenderingRebuildsThroughTheRestartPath() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }

        try fireProbe(rig)

        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.5)
        XCTAssertEqual(rig.state.readCount, 1, "the rebuild was decided on the probe's own read")
        XCTAssertEqual(
            rig.capture.deviceChangeCoordinator.state, .idle,
            "the rebuild completed through the coordinator, not beside it",
        )
        XCTAssertTrue(rig.capture.isRunning, "the rebuilt tap was adopted")
        let counters = try XCTUnwrap(rig.capture.silentTrackDiagnostics.watchdogCounters)
        XCTAssertEqual(counters.noFirstBufferChecks, 1)
        XCTAssertEqual(counters.rebuilds, 1)
    }

    /// A dormant aggregate waiting for an idle target wakes by itself; a
    /// rebuild would only roll the dice on the restart wedge (issue #588).
    func testAProbeWithNothingRenderingRebuildsNothing() throws {
        let rig = try startedRig(running: false)
        defer { rig.capture.stop() }

        try fireProbe(rig)
        settle()

        XCTAssertEqual(rig.state.readCount, 1, "precondition: the processes were asked")
        XCTAssertEqual(rig.attempts.starts, 1, "no rebuild")
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.declined, 1)
    }

    /// Off must mean what it meant before this trigger existed: the probe
    /// logs its reading and nothing acts on it.
    func testWithTheWatchdogOffTheProbeOnlyLogs() throws {
        let rig = try startedRig(watchdog: false)
        defer { rig.capture.stop() }

        try fireProbe(rig)
        settle()

        XCTAssertEqual(rig.state.readCount, 1, "the probe still reads")
        XCTAssertEqual(rig.attempts.starts, 1, "no rebuild")
        XCTAssertNil(rig.capture.silentTrackDiagnostics.watchdogCounters)
    }

    /// A restart attempt that outlives its deadline is discarded when it
    /// returns, and like every attempt it armed probes for the tap it built.
    /// They go with it: fired, they would read a destroyed aggregate and open
    /// checks on a channel that has been given up.
    func testTheProbesOfADiscardedStaleAttemptAreDisarmed() throws {
        let rig = try Rig.started(armsProbes: true)
        defer { rig.capture.stop() }
        XCTAssertEqual(rig.deadlines.pending(at: 5).count, 1, "precondition: the first tap armed its probes")
        let gaveUp = expectation(description: "the restart deadline gave up")
        rig.capture.onGiveUp = { gaveUp.fulfill() }
        rig.attempts.hang = true

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)
        XCTAssertEqual(rig.attempts.starts, 2, "precondition: the rebuild's attempt ran and is stuck")
        XCTAssertTrue(rig.deadlines.pending(at: 5).isEmpty, "precondition: the stop disarmed the first tap's probes")

        // The stuck attempt returns, arms probes for the tap it built, and is
        // rejected as stale.
        rig.attempts.release.signal()
        settle(0.5)

        XCTAssertEqual(rig.deadlines.armedCount(at: 5), 2, "precondition: the stale attempt armed its probes")
        XCTAssertTrue(rig.deadlines.pending(at: 5).isEmpty, "the stale attempt's probes were disarmed with it")
    }
}
