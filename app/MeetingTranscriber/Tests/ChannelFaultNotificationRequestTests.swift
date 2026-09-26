import AudioTapLib
@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// The capture-fault verdict, carried through the real `NotificationManager`
/// to the request it hands the notification centre.
///
/// The other channel-fault suites stop at a spy `AppNotifying`, which records
/// the urgency the controller asked for but not what the manager made of it.
/// This one stops one layer further down, at the `UNNotificationRequest` given
/// to the scheduler, which is the last point this process controls: whether
/// macOS then shows it depends on the user's notification settings.
@MainActor
final class ChannelFaultNotificationRequestTests: XCTestCase {
    func testADeadMicrophoneReachesTheSchedulerAsATimeSensitiveRequest() throws {
        let scheduler = FakeNotificationScheduler()
        let manager = NotificationManager(scheduler: scheduler) { true }
        manager.setUp()
        let controller = ChannelHealthController(
            notifier: manager, debounceSeconds: { 30 }, indicatorEnabled: { false },
        )
        controller.simulateStartForTests()
        let recorder = MockRecorder()
        recorder.micSignalAges = .unknown
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        let request = try XCTUnwrap(
            scheduler.added.first { $0.content.title == "Capture Channel Silent" },
            "scheduled: \(scheduler.added.map(\.content.title))",
        )
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(
            request.content.body,
            ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers, everCarriedSignal: false),
        )
    }
}
