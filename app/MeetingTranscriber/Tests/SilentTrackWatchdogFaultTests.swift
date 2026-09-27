import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// What the user hears when the opt-in silent-track watchdog stops rebuilding
/// the app tap (issue #672): one "Capture Channel Silent" notification with
/// its own body, through the same fault monitor and notification path as the
/// other channel faults. Not "Capture Channel Lost": that copy says the channel
/// stopped and asks for a restart, and after a watchdog give-up the channel is
/// still capturing.
@MainActor
final class SilentTrackWatchdogFaultTests: XCTestCase {
    private let window: TimeInterval = 90
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let deliveringSilence = ChannelHealthHarness.deliveringSilence

    // MARK: - The monitor

    func testTheWatchdogGiveUpIsReportedAtOnceAndOnce() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(
            monitor.update(
                ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 0,
                corroborated: true, rebuildsExhausted: true,
            ),
            .rebuildsExhausted,
            "the watchdog has already waited minutes; a second window adds nothing",
        )
        XCTAssertNil(monitor.update(
            ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 600,
            corroborated: true, rebuildsExhausted: true,
        ))
    }

    /// The order the field case produces: the channel is reported silent after
    /// the window, and the watchdog gives up minutes later. The second report
    /// is new news, the automatic remedy was tried, so it is not swallowed by
    /// the silence latch.
    func testItIsStillReportedAfterTheSilenceReport() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(
            monitor.update(ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 600, corroborated: true),
            .digitalSilence,
        )
        XCTAssertEqual(
            monitor.update(
                ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 700,
                corroborated: true, rebuildsExhausted: true,
            ),
            .rebuildsExhausted,
        )
    }

    /// The watchdog cannot tell a dead tap from a far end that is silent: a
    /// muted call, a lobby, a hold. Like `digitalSilence` (issue #614) it
    /// waits until the other channel shows the call is live, and since the
    /// flag stays set, reports as soon as it does.
    func testItWaitsForTheOtherChannelToCorroborate() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertNil(monitor.update(
            ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 300,
            corroborated: false, rebuildsExhausted: true,
        ))
        XCTAssertEqual(
            monitor.update(
                ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 310,
                corroborated: true, rebuildsExhausted: true,
            ),
            .rebuildsExhausted,
        )
    }

    /// It is a silence report with one more fact in it, so a plain silence
    /// report after it would say less than what the user already has.
    func testItEndsSilenceReportingForTheChannel() {
        var monitor = ChannelFaultMonitor(window: window)
        _ = monitor.update(
            ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 0,
            corroborated: true, rebuildsExhausted: true,
        )
        XCTAssertNil(monitor.update(ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 600, corroborated: true))
    }

    /// The watchdog report ends silence reporting, not reporting: a channel
    /// that later stops delivering altogether is a different failure, with
    /// different advice, and is still reported.
    func testAChannelThatLaterStopsDeliveringIsStillReported() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(
            monitor.update(
                ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 300,
                corroborated: true, rebuildsExhausted: true,
            ),
            .rebuildsExhausted,
        )
        let stopped = ChannelSignalAges(secondsSinceLastBuffer: window + 10, secondsSinceLastEnergy: 600)
        XCTAssertEqual(
            monitor.update(
                ages: stopped, gaveUp: false, elapsedSinceStart: 500,
                corroborated: true, rebuildsExhausted: true,
            ),
            .noBuffers,
        )
    }

    /// A later give-up of the capture itself still gets through: it says the
    /// channel stopped for good, which the watchdog's report does not.
    func testALaterCaptureGiveUpIsStillReported() {
        var monitor = ChannelFaultMonitor(window: window)
        _ = monitor.update(
            ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 0,
            corroborated: true, rebuildsExhausted: true,
        )
        XCTAssertEqual(
            monitor.update(
                ages: deliveringSilence, gaveUp: true, elapsedSinceStart: 60,
                corroborated: false, rebuildsExhausted: true,
            ),
            .gaveUp,
        )
    }

    func testNothingAfterACaptureGiveUp() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(monitor.update(ages: .unknown, gaveUp: true, elapsedSinceStart: 0, corroborated: false), .gaveUp)
        XCTAssertNil(monitor.update(
            ages: .unknown, gaveUp: true, elapsedSinceStart: 60,
            corroborated: true, rebuildsExhausted: true,
        ))
    }

    // MARK: - The copy

    func testTheCopyIsSilentNotLostAndPiercesFocus() {
        let alert = ChannelHealthController.captureAlert(
            channel: .app, fault: .rebuildsExhausted, everCarriedSignal: true,
        )
        XCTAssertEqual(alert.title, "Capture Channel Silent")
        XCTAssertEqual(alert.urgency, .timeSensitive)
    }

    /// What to do, where to do it, and nothing it cannot know. It cannot know
    /// whether anyone was talking: a process rendering a silent far end reports
    /// its output running exactly like one whose audio the tap lost.
    func testTheBodyNamesTheRemedyAndDoesNotClaimTheCallWasAudible() {
        let body = ChannelHealthController.faultMessage(
            channel: .app, fault: .rebuildsExhausted, everCarriedSignal: true,
        )
        XCTAssertTrue(
            body.contains("rebuilding the capture \(SilentTrackWatchdogLimits.rebuildsWithoutSignal) times"), body,
        )
        XCTAssertTrue(body.contains("Control Center"), body)
        XCTAssertTrue(body.contains(SystemSettingsPaths.soundOutput), body)
        XCTAssertTrue(body.contains("If the other participants are talking"), body)
        XCTAssertTrue(body.contains("The recording continues"), body)
        XCTAssertFalse(body.contains("Restart Meeting Transcriber"), "the channel did not stop")
        XCTAssertFalse(body.contains(SystemSettingsPaths.screenRecording), "a tap that carried audio is not a permission problem")
    }

    // MARK: - Through the controller

    func testAWatchdogGiveUpReachesTheUserOnceThroughTheController() {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make(for: self)
        recorder.appLevelDBFS = -120
        recorder.micLevelDBFS = -20
        recorder.appSignalAges = deliveringSilence

        controller.applyTick(recorder: recorder, now: t0)
        recorder.appSilentTrackWatchdogGaveUp = true
        for offset in stride(from: 10.0, through: 300.0, by: 10.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        let expectedBody = ChannelHealthController.faultMessage(
            channel: .app, fault: .rebuildsExhausted, everCarriedSignal: true,
        )
        XCTAssertEqual(notifier.calls.filter { $0.body == expectedBody }.count, 1)
        XCTAssertFalse(notifier.calls.contains { $0.title == "Capture Channel Lost" })
        XCTAssertEqual(controller.appFault, .rebuildsExhausted)
    }

    /// A watchdog give-up while the microphone carries nothing, a lobby or a
    /// muted call, is not reported: nothing corroborates that the call is live.
    func testAWatchdogGiveUpWithASilentMicrophoneIsNotReported() {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make(for: self)
        recorder.appLevelDBFS = -120
        recorder.micLevelDBFS = -120
        recorder.appSignalAges = deliveringSilence
        recorder.appSilentTrackWatchdogGaveUp = true

        for offset in stride(from: 0.0, through: 300.0, by: 10.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        let watchdogBody = ChannelHealthController.faultMessage(
            channel: .app, fault: .rebuildsExhausted, everCarriedSignal: true,
        )
        XCTAssertFalse(notifier.calls.contains { $0.body == watchdogBody })
        XCTAssertNotEqual(controller.appFault, .rebuildsExhausted)
    }

    /// Off, or on and never exhausted, the controller behaves as before.
    func testWithoutAWatchdogGiveUpNothingNewIsReported() {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make(for: self)
        recorder.appLevelDBFS = -120
        recorder.micLevelDBFS = -20
        recorder.appSignalAges = deliveringSilence

        for offset in stride(from: 0.0, through: 300.0, by: 10.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        let watchdogBody = ChannelHealthController.faultMessage(
            channel: .app, fault: .rebuildsExhausted, everCarriedSignal: true,
        )
        XCTAssertFalse(notifier.calls.contains { $0.body == watchdogBody })
        XCTAssertNotEqual(controller.appFault, .rebuildsExhausted)
    }
}
