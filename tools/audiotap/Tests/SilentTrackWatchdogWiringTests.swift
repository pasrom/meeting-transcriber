@testable import AudioTapLib
import CoreAudio
import XCTest

/// The opt-in silent-track watchdog wired into a real `AppAudioCapture`
/// (issue #672): a check reads the tapped processes, a process still rendering
/// turns it into a rebuild request, the main queue re-checks it against the
/// present, and the rebuild runs through the same coordinator, arbiter and
/// attempt the device-change restart uses. The hardware is replaced at the
/// existing seams: `attemptBody` for the tap, the diagnostics probe for the
/// process-state read, and `signalAgesOverride` for the track's ages, because a
/// minute of zeros cannot be produced through the level publisher here. The
/// thresholds themselves are pinned in `SilentTrackWatchdogPolicyTests`.
@available(macOS 14.2, *)
final class SilentTrackWatchdogWiringTests: XCTestCase {
    private let processes = [TappedProcess(pid: 1, audioObjectID: 11)]
    private let interval = SilentTrackWatchdogPolicy.minSecondsBetweenChecks
    private let recovery = SilentTrackWatchdogPolicy.recoveryWindowSeconds

    /// One capture with its hardware stand-ins and its clock.
    private struct Rig {
        let capture: AppAudioCapture
        let attempts: Attempts
        let state: ProcessState
        let clock: TestClock
        let deadlines: Deadlines
    }

    /// A capture wired to the stand-ins, not yet started. `readAges` is what
    /// the capture reads as the track's live ages; by default the ages of a
    /// run still going.
    private func makeRig(
        watchdog: Bool = true,
        running: Bool = true,
        hold: Bool = false,
        readAges: @escaping @Sendable () -> ChannelSignalAges = { ages(energy: 65) },
        // After `readAges`, so a trailing closure keeps binding to that one.
        sink: @escaping SilentTrackDiagnostics.Sink = { _, _ in },
    ) -> Rig {
        let attempts = Attempts()
        let state = ProcessState()
        let clock = TestClock()
        let deadlines = Deadlines()
        state.running = running
        state.hold = hold
        let readClock: @Sendable () -> TimeInterval = { clock.read() }
        return Rig(
            capture: AppAudioCapture(
                pids: [1],
                outputFileDescriptor: FileHandle.nullDevice.fileDescriptor,
                attemptBody: { try attempts.run() },
                silentTrackDiagnostics: SilentTrackDiagnostics(
                    probe: state.probe, sink: sink, delayedWork: deadlines.schedule,
                ),
                silentTrackWatchdog: watchdog,
                signalAgesOverride: readAges,
                clockOverride: readClock,
            ),
            attempts: attempts,
            state: state,
            clock: clock,
            deadlines: deadlines,
        )
    }

    /// The same, started. The caller stops it.
    private func startedRig(
        watchdog: Bool = true,
        running: Bool = true,
        hold: Bool = false,
        readAges: @escaping @Sendable () -> ChannelSignalAges = { ages(energy: 65) },
    ) throws -> Rig {
        let rig = makeRig(watchdog: watchdog, running: running, hold: hold, readAges: readAges)
        try rig.capture.start()
        XCTAssertEqual(rig.attempts.starts, 1, "precondition: start() ran one attempt")
        return rig
    }

    /// Let queued main-queue and diagnostics work run, long enough for the
    /// restart path's 0.5 s initial wait to have fired had anything been
    /// scheduled. Used only to show that something did NOT happen.
    private func settle(_ seconds: TimeInterval = 1.0) {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 5)
    }

    // MARK: - The restart path

    func testAZeroRunWithAProcessRenderingRebuildsThroughTheRestartPath() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)

        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.5)
        XCTAssertEqual(rig.state.readCount, 1, "one process-state read per check")
        XCTAssertEqual(
            rig.capture.deviceChangeCoordinator.state, .idle,
            "the rebuild completed through the coordinator, not beside it",
        )
        XCTAssertTrue(rig.capture.isRunning, "the rebuilt tap was adopted")
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuilds, 1)
    }

    func testAZeroRunWithNothingRenderingRebuildsNothing() throws {
        let rig = try startedRig(running: false)
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        settle()

        XCTAssertEqual(rig.state.readCount, 1, "precondition: the processes were asked")
        XCTAssertEqual(rig.attempts.starts, 1, "no rebuild")
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.declined, 1)
    }

    /// Three rebuilds that restore nothing, then one give-up reported on the
    /// main queue, then no fourth rebuild.
    func testThreeFruitlessRebuildsEndInOneGiveUp() throws {
        let rig = makeRig()
        let capture = rig.capture
        let gaveUp = expectation(description: "watchdog give-up reported")
        capture.onSilentTrackWatchdogGaveUp = {
            XCTAssertTrue(Thread.isMainThread)
            gaveUp.fulfill()
        }
        capture.onGiveUp = { XCTFail("the capture itself did not give up") }
        try capture.start()
        defer { capture.stop() }

        for rebuild in 1 ... SilentTrackWatchdogPolicy.maxUnrecoveredRebuilds {
            let now = 1000 + Double(rebuild - 1) * interval
            rig.clock.now = now
            capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61 + now - 1000), now: now, processes: processes)
            wait(for: [rig.attempts.expectation(reaching: 1 + rebuild)], timeout: RestartArbiter.attemptTimeout + 5)
            settle(0.3)
            // Close the rebuild as unrecovered: the window passes on the same
            // clock its start was stamped with.
            capture.evaluateSilentTrackWatchdog(ages: ages(energy: 200), now: now + recovery + 1, processes: processes)
        }
        let last = 1000 + Double(SilentTrackWatchdogPolicy.maxUnrecoveredRebuilds) * interval
        capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61 + last - 1000), now: last, processes: processes)
        wait(for: [gaveUp], timeout: 5)
        settle()

        XCTAssertEqual(rig.attempts.starts, 1 + SilentTrackWatchdogPolicy.maxUnrecoveredRebuilds, "no fourth rebuild")
        XCTAssertEqual(capture.silentTrackDiagnostics.watchdogCounters?.gaveUp, true)
    }

    /// Signal inside the recovery window after a real rebuild is credited to
    /// it. Deterministic because the rebuild's start and the evaluation read
    /// the same clock.
    func testSignalRightAfterARebuildIsCreditedToIt() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.3)
        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 1), now: 1005, processes: processes)

        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuilds, 1)
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.recoveries, 1)
    }

    /// The rebuild's restart gives up: every attempt throws until the retry
    /// budget is spent. That rebuild ended the channel, and the watchdog's
    /// record says so.
    func testARebuildWhoseRestartGivesUpIsRecordedAsEndingTheChannel() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        // Typed local, not a trailing closure: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
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

        let counters = rig.capture.silentTrackDiagnostics.watchdogCounters
        XCTAssertEqual(counters?.rebuilds, 1)
        XCTAssertEqual(counters?.endedChannel, true)
    }

    /// The rebuild's attempt never returns, the wedge of issue #588. The
    /// restart deadline ends it and gives up on the channel, and that give-up
    /// is the other one the watchdog has to hear: the rebuild ended the
    /// channel, and the evidence the watchdog exists for must say so.
    func testARebuildWhoseAttemptWedgesIsRecordedAsEndingTheChannel() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        // Let the stuck attempt return once the test is over; the arbiter
        // rejects it as stale and it releases only what it built.
        addTeardownBlock { rig.attempts.release.signal() }
        let gaveUp = expectation(description: "the restart deadline gave up")
        rig.capture.onGiveUp = { gaveUp.fulfill() }
        rig.attempts.hang = true

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)

        XCTAssertEqual(rig.attempts.starts, 2, "precondition: the rebuild's attempt ran and is stuck")
        let counters = rig.capture.silentTrackDiagnostics.watchdogCounters
        XCTAssertEqual(counters?.rebuilds, 1)
        XCTAssertEqual(counters?.endedChannel, true)
    }

    // MARK: - A rebuilt tap that never delivers

    /// The rebuild's tap is installed and never delivers a buffer (the #693
    /// failure), so no tick will ever judge it. The deadline its installation
    /// armed closes it, and nothing is rebuilt on the strength of that alone.
    func testARebuiltTapThatDeliversNothingIsClosedByItsDeadline() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.3)
        let deadline = try XCTUnwrap(
            rig.deadlines.pending(at: recovery).first, "installing the rebuilt tap armed a deadline",
        )
        deadline.perform()
        settle(0.3)

        let counters = rig.capture.silentTrackDiagnostics.watchdogCounters
        XCTAssertEqual(counters?.rebuiltTapSilent, 1)
        XCTAssertEqual(counters?.rebuilds, 1)
        XCTAssertEqual(rig.attempts.starts, 2, "the verdict alone rebuilds nothing")
        let summary = try XCTUnwrap(rig.capture.silentTrackWatchdogSummary)
        XCTAssertTrue(summary.contains("watchdogRebuiltTapSilent=1"), "the stop summary carries it")
    }

    /// The rebuilt tap delivered, so ticks will come and judge the rebuild:
    /// the deadline stands down.
    func testARebuiltTapThatDeliveredLeavesTheVerdictToTheTick() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        wait(for: [rig.attempts.expectation(reaching: 2)], timeout: RestartArbiter.attemptTimeout + 5)
        settle(0.3)
        let deadline = try XCTUnwrap(rig.deadlines.pending(at: recovery).first, "precondition: a deadline was armed")
        // What the IOProc's first callback does; a stand-in tap runs no IOProc.
        rig.capture.silentTrackDiagnostics.watchdogRebuiltTapDelivered()
        deadline.perform()

        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuiltTapSilent, 0)
        XCTAssertNil(rig.capture.silentTrackDiagnostics.watchdogRebuildAwaitingFirstBuffer)
    }

    /// The recording's own first tap is not a rebuild and arms nothing.
    func testTheFirstTapArmsNoDeadline() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        settle(0.3)

        XCTAssertTrue(rig.deadlines.pending(at: recovery).isEmpty)
    }

    // MARK: - The 5 s tick

    /// The real tick entry reads the track's ages once and hands them to both
    /// the observer and the watchdog, and the watchdog reads its clock once.
    func testTheTickReadsTheAgesOnceForBothConsumers() {
        let reads = CallCounter()
        let rig = makeRig {
            reads.increment()
            return ages(energy: 61)
        }
        _ = rig.capture.debugRMS.tick(intervalSeconds: 0)

        rig.capture.maybeReportDebugRMS(processes: processes)
        settle(0.3)

        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(rig.clock.reads, 1)
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.checks, 1, "the watchdog acted on them")
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.counters.zeroRuns, 1, "and so did the observer")
    }

    /// Off, the tick still reads the ages once, for the observer, and the
    /// watchdog neither reads the clock nor holds any state. (The observer's
    /// own zero-run probe still reads the processes, which is why that count
    /// is not asserted here.)
    func testTheTickWithTheWatchdogOffLeavesTheWatchdogOut() {
        let reads = CallCounter()
        let rig = makeRig(watchdog: false) {
            reads.increment()
            return ages(energy: 61)
        }
        _ = rig.capture.debugRMS.tick(intervalSeconds: 0)

        rig.capture.maybeReportDebugRMS(processes: processes)
        settle(0.3)

        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(rig.clock.reads, 0)
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.counters.zeroRuns, 1, "the observer still ran")
        XCTAssertNil(rig.capture.silentTrackDiagnostics.watchdogCounters)
    }

    // MARK: - Re-check before acting

    /// Signal came back between the check and the main queue getting to it.
    func testARequestIsDroppedWhenSignalReturnedMeanwhile() throws {
        let rig = try startedRig { ages(energy: 0.3) }
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        settle()

        XCTAssertEqual(rig.state.readCount, 1, "precondition: the check ran")
        XCTAssertEqual(rig.attempts.starts, 1, "no rebuild")
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuilds, 0)
    }

    /// A device-change restart installed another tap between the check and the
    /// rebuild. Installed here synchronously, before the main queue can run the
    /// request, which is the same ordering without the race.
    func testARequestIsDroppedWhenAnotherTapWasInstalledMeanwhile() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        rig.capture.install(Attempts.session(tapID: 42))
        settle()

        XCTAssertEqual(rig.state.readCount, 1, "precondition: the check ran")
        XCTAssertEqual(rig.attempts.starts, 1, "the replacement tap was not rebuilt")
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuilds, 0)
    }

    /// A restart already in flight takes the tap down and up anyway. The
    /// coordinator refuses the rebuild, and a refused rebuild is not counted:
    /// counting it would spend the budget on rebuilds that never happened.
    func testARebuildTheRestartPathRefusesIsNotCounted() throws {
        let rig = try startedRig()
        defer { rig.capture.stop() }
        _ = rig.capture.deviceChangeCoordinator.handle(.deviceChanged)

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        settle()

        XCTAssertEqual(rig.state.readCount, 1, "precondition: the check ran")
        XCTAssertEqual(rig.attempts.starts, 1)
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuilds, 0)
    }

    // MARK: - Stop

    /// A probe still inside the HAL when the recording stops answers into a
    /// stopped watchdog: no rebuild, no counter, no give-up after the summary.
    func testAProbeThatAnswersAfterStopChangesNothing() throws {
        let rig = try startedRig(hold: true)

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        XCTAssertEqual(rig.state.entered.wait(timeout: .now() + 2), .success, "precondition: the probe is in flight")
        rig.capture.stop()
        rig.state.hold = false
        rig.state.release.signal()
        settle()

        XCTAssertEqual(rig.attempts.starts, 1)
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.rebuilds, 0)
        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.declined, 0)
        XCTAssertTrue(rig.capture.silentTrackDiagnostics.watchdogStopped)
    }

    /// Another probe's read that never comes back (issue #588), such as the
    /// observer's at the start of the zero run, skips every later check, once
    /// a minute for as long as the run lasts. Those skips stay inside the
    /// watchdog's own line budget: the shared sink would write one per check,
    /// without a bound, for the rest of the recording. (The watchdog's own
    /// read wedging needs no budget: its check stays open and blocks the next.)
    func testChecksSkippedBehindAWedgedReadStayInsideTheLineBudget() {
        let skipsInSink = CallCounter()
        let countSkips: SilentTrackDiagnostics.Sink = { _, outcome in
            if outcome == .skipped { skipsInSink.increment() }
        }
        let rig = makeRig(hold: true, sink: countSkips)
        defer {
            rig.state.hold = false
            rig.state.release.signal()
        }
        rig.capture.silentTrackDiagnostics.probeAsync(processes, aggregateID: 0, reason: "zero run started")
        XCTAssertEqual(rig.state.entered.wait(timeout: .now() + 2), .success, "precondition: the read is stuck")

        let skipped = SilentTrackWatchdogPolicy.maxLoggedSkips + 5
        for check in 1 ... skipped {
            let now = 1000 + Double(check) * interval
            rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61 + now - 1000), now: now, processes: processes)
        }

        XCTAssertEqual(rig.capture.silentTrackDiagnostics.watchdogCounters?.dropped, skipped, "precondition")
        XCTAssertEqual(skipsInSink.value, 0, "the watchdog's skips are not the sink's to log")
        XCTAssertFalse(
            rig.capture.silentTrackDiagnostics.watchdogClaimSkipLine(),
            "they were logged against the watchdog's budget, which is now spent",
        )
    }

    // MARK: - Off

    /// Off is the default and must mean no behaviour change: the same tick that
    /// rebuilds with the watchdog on reads no process state, starts no attempt,
    /// never re-reads the live ages, holds no watchdog state and adds nothing
    /// to the stop summary.
    func testOffTheSameTickDoesNothingAtAll() throws {
        let reads = CallCounter()
        let rig = try startedRig(watchdog: false) {
            reads.increment()
            return ages(energy: 61)
        }
        defer { rig.capture.stop() }

        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 3600), now: 5000, processes: processes)
        rig.capture.tickSilentTrackWatchdog(ages: ages(energy: 3600), processes: processes)
        settle()

        XCTAssertEqual(rig.state.readCount, 0)
        XCTAssertEqual(rig.attempts.starts, 1)
        XCTAssertEqual(reads.value, 0, "nothing asked for the live ages")
        XCTAssertFalse(rig.capture.silentTrackWatchdog)
        XCTAssertNil(rig.capture.silentTrackDiagnostics.watchdogCounters)
        XCTAssertNil(rig.capture.silentTrackWatchdogSummary)
    }

    func testTheStopSummaryCarriesTheCountersWhenOn() {
        let rig = makeRig(running: false)
        rig.capture.evaluateSilentTrackWatchdog(ages: ages(energy: 61), now: 1000, processes: processes)
        settle(0.3)
        XCTAssertEqual(
            rig.capture.silentTrackWatchdogSummary,
            "watchdogChecks=1 watchdogDeclined=1 watchdogDropped=0 watchdogRebuilds=0 "
                + "watchdogRecoveries=0 watchdogGaveUp=false watchdogCapped=false watchdogEndedChannel=false "
                + "watchdogRebuiltTapSilent=0",
        )
    }

    // MARK: - Configuration to capture

    func testTheSessionHandsTheOptionToTheAppCapture() {
        func capture(_ watchdog: Bool) -> AppAudioCapture {
            AudioCaptureSession.makeAppCapture(
                AudioCaptureConfiguration(
                    pids: [1], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2,
                    silentTrackWatchdog: watchdog,
                ),
                fileDescriptor: FileHandle.nullDevice.fileDescriptor,
                attemptBody: nil,
            )
        }
        XCTAssertNotNil(capture(true).silentTrackDiagnostics.watchdogCounters)
        XCTAssertNil(capture(false).silentTrackDiagnostics.watchdogCounters)
    }

    /// Every configuration that does not mention the option, most callers in
    /// this package among them, must get it off.
    func testTheOptionIsOffByDefault() {
        let configuration = AudioCaptureConfiguration(
            pids: [], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2,
        )
        XCTAssertFalse(configuration.silentTrackWatchdog)
    }

    // MARK: - The probe's second consumer

    func testAProbeOutsideTheSinkStillReachesItsContinuation() {
        let sinkCalls = CallCounter()
        let diagnostics = SilentTrackDiagnostics(
            probe: { _, _ in .init(processes: [], device: nil) },
            sink: { _, _ in sinkCalls.increment() },
        )
        let heard = expectation(description: "continuation ran")
        diagnostics.probeAsync(processes, aggregateID: 0, reason: "watchdog check", reportToSink: false) { _ in
            heard.fulfill()
        }
        wait(for: [heard], timeout: 2)
        XCTAssertEqual(sinkCalls.value, 0)
    }
}

/// A counter bumped from whichever queue the code under test runs on.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
