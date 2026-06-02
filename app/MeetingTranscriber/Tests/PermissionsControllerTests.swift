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
