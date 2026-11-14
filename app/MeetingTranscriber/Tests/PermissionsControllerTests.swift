@testable import MeetingTranscriber
import XCTest

/// Unit tests for `PermissionsController` — the first concern-specific
/// controller extracted from the `AppState` god-class.
///
/// These construct a bare `PermissionsController(notifier:)` rather than a full
/// `AppState`, so they don't pay the AppState init cost (pipeline queue,
/// channel-health monitors, live-transcription prewarm, and — in non-AppStore
/// builds — the persistent-log-streamer subprocess). The injected `probe` seam
/// also lets the debounce logic be tested without the real ~500 ms `runLive()`
/// TCC probe, which was impossible while the call was hard-wired into AppState.
@MainActor
final class PermissionsControllerTests: XCTestCase {
    // MARK: - handle: notification behaviour (moved from AppStateTests)

    func testHandleBrokenSendsNotification() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        controller.handle(HealthCheckResult(screenRecording: .broken, microphone: .healthy))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(notifier.calls.first?.title.contains("Permission") ?? false)
    }

    func testHandleHealthyNoNotification() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        controller.handle(HealthCheckResult(screenRecording: .healthy, microphone: .healthy))
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testHandleStoresResult() {
        let controller = PermissionsController(notifier: RecordingNotifier())
        let result = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        controller.handle(result)
        XCTAssertEqual(controller.health, result)
    }

    func testHandleDedupsRepeatedProblem() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        let broken = HealthCheckResult(screenRecording: .healthy, microphone: .broken)
        controller.handle(broken)
        controller.handle(broken)
        controller.handle(broken)
        XCTAssertEqual(notifier.calls.count, 1, "Identical problem set should only notify once")
    }

    func testHandleReNotifiesAfterRecovery() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        let broken = HealthCheckResult(screenRecording: .healthy, microphone: .broken)
        let healthy = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        controller.handle(broken) // notify #1
        controller.handle(healthy) // clears dedup memory
        controller.handle(broken) // notify #2
        XCTAssertEqual(notifier.calls.count, 2)
    }

    func testHandleNotifiesWhenProblemChanges() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        controller.handle(HealthCheckResult(screenRecording: .healthy, microphone: .broken))
        controller.handle(HealthCheckResult(screenRecording: .broken, microphone: .healthy))
        XCTAssertEqual(notifier.calls.count, 2, "Different problem sets should each trigger a notification")
    }

    func testHandleAccessibilityBrokenNotifies() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        controller.handle(HealthCheckResult(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        ))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(notifier.calls.first?.body.contains("Accessibility") ?? false)
    }

    // MARK: - check: probe + debounce (impossible before extraction)

    func testCheckRunsProbeAndStoresHealth() async {
        let probed = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        let controller = PermissionsController(notifier: RecordingNotifier()) { probed }
        await controller.check()
        XCTAssertEqual(controller.health, probed)
        XCTAssertNotNil(controller.lastCheckAt)
    }

    func testRepeatedCheckWithinMinimumIntervalSkipsProbe() async {
        let counter = ProbeCounter()
        let controller = PermissionsController(notifier: RecordingNotifier(), probe: counter.probe)
        // First call: no prior timestamp → always runs.
        await controller.check(minimumInterval: 9999)
        // Second call: last check was milliseconds ago, well within 9999 s → skipped.
        await controller.check(minimumInterval: 9999)
        XCTAssertEqual(counter.count, 1, "Second check within the minimum interval should be debounced")
    }

    func testCheckWithNilIntervalAlwaysRunsProbe() async {
        let counter = ProbeCounter()
        let controller = PermissionsController(notifier: RecordingNotifier(), probe: counter.probe)
        await controller.check()
        await controller.check()
        XCTAssertEqual(counter.count, 2, "A nil minimum interval must never debounce")
    }

    // MARK: - check: one probe at a time (issue #778)

    /// A probe that parks on `gate` and counts on exit, so a test can hold one
    /// check open while a second one arrives.
    private func gatedProbe(_ gate: MainActorGate, _ counter: ProbeCounter) -> () async -> HealthCheckResult {
        { await gate.wait(); return counter.probe() }
    }

    /// Runs one check as far as the gated probe, then has a second caller open
    /// the gate and call `check()` in the same main-actor turn, and waits for both.
    ///
    /// The join is decided the moment a caller enters `check()`: it reads whether
    /// a run is in flight and awaits that run or starts its own, with no suspension
    /// in between. Opening the gate only enqueues the parked probe, so the released
    /// run cannot finish before the second caller has entered and made that
    /// decision (see `MainActorGate`). The order holds by construction; two sibling
    /// tasks would leave it to the scheduler, and a late second caller finds no
    /// run to join.
    ///
    /// It rests on `check()` not suspending ahead of the join. With an `await`
    /// there the released run could finish first, and these tests would no longer
    /// pin the order.
    private func runCheckWithJoiner(
        on controller: PermissionsController,
        heldBy gate: MainActorGate,
        joinerInterval: TimeInterval? = nil,
    ) async {
        let first = Task { @MainActor in await controller.check() }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        guard gate.hasWaiter else {
            gate.open()
            XCTFail("the first check never parked in its probe")
            return
        }
        let joiner = Task { @MainActor in
            gate.open()
            await controller.check(minimumInterval: joinerInterval)
        }
        let firstReturned = await value(of: first) != nil
        let joinerReturned = await value(of: joiner) != nil
        XCTAssertTrue(firstReturned, "the first check never returned")
        XCTAssertTrue(joinerReturned, "the second check never returned")
    }

    func testCheckDuringARunningCheckJoinsItInsteadOfProbingAgain() async {
        // The debounce only knows about checks that have finished (`lastCheckAt`
        // is written after the probe returns), so a check arriving while one is
        // out used to open a second engine on the same microphone.
        let gate = MainActorGate()
        let counter = ProbeCounter()
        let controller = PermissionsController(notifier: RecordingNotifier(), probe: gatedProbe(gate, counter))

        await runCheckWithJoiner(on: controller, heldBy: gate, joinerInterval: 3)

        XCTAssertEqual(counter.count, 1, "the second check must join the running probe, not start its own")
        XCTAssertNotNil(controller.health, "the joined check reports the shared result")
        XCTAssertNotNil(controller.lastCheckAt)
    }

    func testCheckAfterAJoinedCheckProbesAgain() async {
        // Joining is per run, not forever: once the shared probe has answered,
        // the next undebounced check runs its own.
        let gate = MainActorGate()
        let counter = ProbeCounter()
        let controller = PermissionsController(notifier: RecordingNotifier(), probe: gatedProbe(gate, counter))
        await runCheckWithJoiner(on: controller, heldBy: gate)
        XCTAssertEqual(counter.count, 1, "the joined check must not have probed on its own")
        await controller.check()
        XCTAssertEqual(counter.count, 2)
    }
}

/// Counts how many times the injected probe ran. `@MainActor` to match the
/// controller's isolation; `probe` is synchronous and gets promoted to the
/// `() async -> HealthCheckResult` seam when passed in.
@MainActor
private final class ProbeCounter {
    private(set) var count = 0
    func probe() -> HealthCheckResult {
        count += 1
        return HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
    }
}
