@testable import MeetingTranscriber
import XCTest

/// The controller half of `/v1/record`: idempotent microphone start/stop, and
/// the two refusals that make it a resource of its own rather than a verb on
/// `/v1/watch`.
///
/// Nothing here touches real audio hardware. Cases that only need a recording to
/// exist inject a `makeTestWatchLoop` loop; cases that assert a start actually
/// happens go through the controller's own start path, which the factory wires
/// to a `MockRecorder` — `DualSourceRecorder` writes into the production staging
/// directory, which is not somewhere a unit test may leave files. Real
/// microphone capture is covered by the live lane, not from here.
@MainActor
final class WatchingControllerRecordControlTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerRecordControlTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    // MARK: - Start

    func testStartRecordsTheMicrophoneAndReportsTheChange() async {
        let controller = makeWatchingController(logDir: tmpDir, permissionHealth: .allHealthy)
        addTeardownBlock { await controller.stopManualRecording() }

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .changed)
        XCTAssertTrue(controller.isRecordingMicrophoneOnly)
    }

    /// Already recording is a satisfied request, not an error — the same rule
    /// `/v1/watch` follows. The second half is the one that matters: the repeat
    /// must not build a second loop over the live one, which is the loss #624
    /// was about.
    func testSecondStartIsUnchangedAndKeepsTheRecordingItFound() async throws {
        let controller = makeWatchingController(logDir: tmpDir)
        let loop = try await microphoneRecording(on: controller)

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertIdentical(controller.watchLoop, loop, "the live recording must keep the loop")
        XCTAssertTrue(controller.isRecordingMicrophoneOnly)
    }

    /// One of the two refusals the endpoint reports as 412. Honouring the
    /// setting by starting anyway would record nothing, and retrying changes
    /// nothing until the user turns it off.
    func testStartIsRefusedWhileTheMicrophoneIsSwitchedOff() async {
        let controller = makeWatchingController(logDir: tmpDir, noMic: true)

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .refused)
        XCTAssertNil(controller.watchLoop, "nothing may be recorded while the microphone is switched off")
    }

    /// The other one. It comes back through the start itself rather than from a
    /// second permission check here, so the refusal names the source the loop
    /// was actually about to record.
    func testStartIsRefusedWhenTheMicrophonePermissionIsDenied() async {
        let controller = makeWatchingController(
            logDir: tmpDir,
            permissionHealth: HealthCheckResult(screenRecording: .healthy, microphone: .denied),
        )

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .refused, "a denied microphone must not read as a transient failure")
        XCTAssertFalse(controller.isRecordingMicrophoneOnly)
    }

    /// Control case for the refusal above: without it, a start that refuses on
    /// *any* permission problem would pass that test just as well. Screen
    /// Recording only ever gated the process tap, and a microphone recording
    /// opens none (#633).
    func testStartProceedsWhileScreenRecordingIsDenied() async {
        let controller = makeWatchingController(
            logDir: tmpDir,
            permissionHealth: HealthCheckResult(screenRecording: .denied, microphone: .healthy),
        )
        addTeardownBlock { await controller.stopManualRecording() }

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .changed, "Screen Recording gates a tap this recording never opens")
        XCTAssertTrue(controller.isRecordingMicrophoneOnly)
    }

    /// 409, and the assertion that carries it is the second one: a refusal that
    /// still clobbered the running recording would be the bug, not the code.
    func testStartIsBlockedWhileAnAppRecordingOwnsTheLoop() async throws {
        let controller = makeWatchingController(logDir: tmpDir)
        let loop = try await appRecording(on: controller)

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .blocked)
        XCTAssertIdentical(controller.watchLoop, loop, "the live recording must keep the loop")
        XCTAssertTrue(loop.isManualRecording)
    }

    /// The refusal that carries the most weight, and the one the ownership
    /// guards inside `beginManualRecording` do *not* provide: an auto-detected
    /// meeting sets no `manualRecordingInfo`, so `isManualRecording` reads false
    /// and a start would sail past them and clobber a meeting in progress. Only
    /// the availability check above stands between a remote key press and that.
    func testStartIsBlockedWhileAnAutoDetectedMeetingIsBeingRecorded() async {
        let controller = makeWatchingController(logDir: tmpDir)
        let (loop, _) = makeTestWatchLoop(detector: FixedMeetingDetector())
        controller.watchLoop = loop
        loop.start()
        addTeardownBlock { await loop.stop() }
        await waitFor(loop.state == .recording, timeout: .seconds(2))
        XCTAssertFalse(loop.isManualRecording, "precondition: this is what makes the guards below insufficient")

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .blocked)
        XCTAssertIdentical(controller.watchLoop, loop, "the meeting's loop must still be the owner")
        XCTAssertEqual(loop.state, .recording, "the meeting must still be recording")
    }

    /// The distinction the endpoint exists to make, in the direction nothing
    /// covered: a recorder that will not start is 503 "try again", NOT the 412
    /// that tells a client to stop retrying until it changes a setting.
    /// Collapsing the error classification to `.permissionRefused` used to leave
    /// the whole suite green.
    func testARecorderFailureIsNotReportedAsARefusal() async {
        // Explicit label, not a trailing closure: `make` takes several
        // function-type parameters and binding by position is exactly the trap
        // the RPC integration tests warn about.
        let controller = makeWatchingController(
            // swiftlint:disable:next trailing_closure
            logDir: tmpDir, permissionHealth: .allHealthy, makeRecorder: { ThrowingRecorder() },
        )

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .failed, "a device that will not open is transient, not a precondition")
        XCTAssertFalse(controller.isRecordingMicrophoneOnly)
    }

    /// A refused start must not leave the machine blind. The start stops an
    /// active auto loop before it knows whether it can record, so without the
    /// re-arm a 412 answers "nothing changed" while detection is off for good.
    func testARefusedStartPutsMeetingWatchingBack() async {
        let controller = makeWatchingController(
            logDir: tmpDir,
            permissionHealth: HealthCheckResult(screenRecording: .healthy, microphone: .denied),
        )
        addTeardownBlock { await controller.stopManualRecording() }
        await controller.startWatching()
        XCTAssertTrue(controller.isWatching, "precondition")

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .refused)
        XCTAssertTrue(controller.isWatching, "a refusal must not switch meeting detection off")
    }

    /// The bound the docs promise, and the half of the predicate that would
    /// otherwise never be exercised: a start already in flight has to be waited
    /// for, once, and the wait has to give up rather than hang on the microphone
    /// prompt the docs name as the cause of a 503.
    func testAStartWaitsForAnInFlightOneWithinASingleBound() async {
        let gate = AsyncGate()
        let controller = makeWatchingController(
            logDir: tmpDir,
            ensureMicAccess: {
                await gate.wait()
                return true
            },
            startJoinTimeout: .milliseconds(80),
        )
        addTeardownBlock {
            await gate.open()
            await controller.stopManualRecording()
        }
        controller.startMicrophoneRecording()
        await waitFor { await gate.hasWaiter }

        let began = ContinuousClock.now
        let outcome = await controller.applyRecordAction(.start)
        let elapsed = ContinuousClock.now - began

        XCTAssertEqual(outcome, .failed, "a start that never settles is a 503, not a hang")
        XCTAssertLessThan(elapsed, .milliseconds(400), "one bound, not two, and not unbounded")
    }

    /// The guard behind the race above, at the only layer that can be pinned:
    /// the interleaving itself (a meeting starting between the caller's check
    /// and the takeover) is not something a test can schedule reliably.
    func testALoopThatIsRecordingMayNotBeTakenOver() {
        XCTAssertFalse(WatchingController.mayTakeOverLoop(in: .recording))
        for state in [WatchLoop.State.idle, .watching, .error] {
            XCTAssertTrue(
                WatchingController.mayTakeOverLoop(in: state),
                "only a recording is untouchable; \(state) may be taken over",
            )
        }
    }

    /// D1, directly: the start this call launches must be bounded too. The
    /// earlier case bounds a start it *found*; remove the wait on the one it
    /// creates and only this one goes red — the endpoint would then hang for as
    /// long as the microphone prompt sits unanswered.
    ///
    /// Driven from a child task with its own deadline rather than awaited
    /// inline, so a regression fails in under a second instead of wedging the
    /// whole run: without the bound the call never returns at all.
    func testTheStartThisCallLaunchesIsBoundedToo() async {
        let gate = AsyncGate()
        let controller = makeWatchingController(
            logDir: tmpDir,
            ensureMicAccess: {
                await gate.wait()
                return true
            },
            permissionHealth: .allHealthy,
            startJoinTimeout: .milliseconds(80),
        )
        addTeardownBlock {
            await gate.open()
            await controller.stopManualRecording()
        }

        let settled = OutcomeBox()
        let call = Task { @MainActor in
            await settled.store(controller.applyRecordAction(.start))
        }
        var outcome: RecordControlOutcome?
        for _ in 0 ..< 80 where outcome == nil {
            outcome = await settled.read()
            if outcome == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        call.cancel()

        XCTAssertEqual(
            outcome, .failed,
            "an unanswered permission prompt must answer 503, not hold the request open",
        )
    }

    // MARK: - Stop

    func testStopEndsAMicrophoneRecording() async throws {
        let controller = makeWatchingController(logDir: tmpDir)
        _ = try await microphoneRecording(on: controller)

        let outcome = await controller.applyRecordAction(.stop)

        XCTAssertEqual(outcome, .changed)
        XCTAssertFalse(controller.isRecordingMicrophoneOnly)
    }

    func testStopWithNothingRecordingIsUnchanged() async {
        let controller = makeWatchingController(logDir: tmpDir)

        let outcome = await controller.applyRecordAction(.stop)

        XCTAssertEqual(outcome, .unchanged)
    }

    /// The refusal that would hurt most if it were missing: a stop aimed at the
    /// microphone reaching across and ending a meeting the caller never started.
    /// Reported as `.unchanged` rather than `.blocked` because no microphone
    /// recording is running, so the asked-for end state already holds.
    func testStopLeavesAnAppRecordingAlone() async throws {
        let controller = makeWatchingController(logDir: tmpDir)
        let loop = try await appRecording(on: controller)

        let outcome = await controller.applyRecordAction(.stop)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(loop.isManualRecording, "an app recording must survive a microphone stop")
        XCTAssertIdentical(controller.watchLoop, loop)
    }

    /// A stop whose recorder throws loses the recording: `WatchLoop` skips the
    /// enqueue, so there is no job and no transcript. Answering 200 there tells
    /// the caller their meeting is safe when it is gone. The mock without a mix
    /// path is exactly that shape, which is also why the factory's default
    /// carries one.
    func testAStopThatLosesTheRecordingIsNotReportedAsSuccess() async {
        let controller = makeWatchingController(
            // swiftlint:disable:next trailing_closure
            logDir: tmpDir, permissionHealth: .allHealthy, makeRecorder: { MockRecorder() },
        )
        addTeardownBlock { await controller.stopManualRecording() }
        let started = await controller.applyRecordAction(.start)
        XCTAssertEqual(started, .changed, "precondition")

        let outcome = await controller.applyRecordAction(.stop)

        XCTAssertEqual(outcome, .failed, "no job was enqueued, so this was not a successful stop")
    }

    // MARK: - Toggle

    func testToggleStartsThenStops() async {
        let controller = makeWatchingController(logDir: tmpDir, permissionHealth: .allHealthy)
        addTeardownBlock { await controller.stopManualRecording() }

        let started = await controller.applyRecordAction(.toggle)
        XCTAssertEqual(started, .changed)
        XCTAssertTrue(controller.isRecordingMicrophoneOnly)

        let stopped = await controller.applyRecordAction(.toggle)
        XCTAssertEqual(stopped, .changed)
        XCTAssertFalse(controller.isRecordingMicrophoneOnly)
    }

    // MARK: - Helpers

    /// A live microphone recording on a mock-recorder loop the controller owns.
    /// Injected rather than started for real, so what these tests measure is the
    /// ownership rule and not the machine's audio hardware.
    private func microphoneRecording(on controller: WatchingController) async throws -> WatchLoop {
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startMicrophoneRecording()
        addTeardownBlock { await loop.stop() }
        return loop
    }

    /// The same, for an app-picker recording — the thing a microphone start must
    /// refuse and a microphone stop must leave alone.
    private func appRecording(on controller: WatchingController) async throws -> WatchLoop {
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting")
        addTeardownBlock { await loop.stop() }
        return loop
    }
}

/// Collects an outcome produced by a child task, so a test can put a deadline
/// on a call that is supposed to be bounded and fail fast when it is not.
actor OutcomeBox {
    private var value: RecordControlOutcome?

    func store(_ outcome: RecordControlOutcome) {
        value = outcome
    }

    func read() -> RecordControlOutcome? {
        value
    }
}

/// A recorder whose `start` fails the way a busy or absent input device does.
/// Injected through the `makeRecorder:` seam so the non-permission failure arm
/// is reachable without hardware.
@MainActor
final class ThrowingRecorder: RecordingProvider {
    func start(source _: RecordingSource, micDeviceUID _: String?, debugLogging _: Bool) throws {
        throw RecorderError.noAudioData
    }

    func stop() throws -> RecordingResult {
        throw RecorderError.notRecording
    }
}
