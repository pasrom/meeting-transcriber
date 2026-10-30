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
    private let watchdogBody = ChannelHealthController.faultMessage(
        channel: .app, fault: .rebuildsExhausted, everCarriedSignal: true,
    )

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

    /// The give-up flag stays set for the rest of the recording, so a report
    /// held back for corroboration can fall due after the far end started
    /// talking again: a lobby that filled, a far end that was only muted.
    /// "Rebuilding did not bring audio back" would then be false, and it
    /// pierces Focus. Signal since the give-up retires the report for good.
    func testAGiveUpTheChannelRecoveredFromIsNotReportedLater() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertNil(monitor.update(
            ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 300,
            corroborated: false, rebuildsExhausted: true,
        ))
        let carrying = ChannelSignalAges.deliveringSignalNow
        XCTAssertNil(monitor.update(
            ages: carrying, gaveUp: false, elapsedSinceStart: 320,
            corroborated: false, rebuildsExhausted: true,
        ))
        XCTAssertNil(
            monitor.update(
                ages: carrying, gaveUp: false, elapsedSinceStart: 330,
                corroborated: true, rebuildsExhausted: true,
            ),
            "the channel carries audio; the give-up is stale",
        )
        // A brief return does not revive it either: the give-up was about the
        // run that ended, and a new run is the plain silence report's.
        let silentAgain = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 30)
        XCTAssertNil(monitor.update(
            ages: silentAgain, gaveUp: false, elapsedSinceStart: 350,
            corroborated: true, rebuildsExhausted: true,
        ))
    }

    /// Retiring a stale give-up must not also silence the channel: a later
    /// run of zeros is reported as digital silence, as it would have been
    /// without the watchdog.
    func testAfterAStaleGiveUpALaterSilenceIsStillReported() {
        var monitor = ChannelFaultMonitor(window: window)
        _ = monitor.update(
            ages: deliveringSilence, gaveUp: false, elapsedSinceStart: 300,
            corroborated: false, rebuildsExhausted: true,
        )
        _ = monitor.update(
            ages: .deliveringSignalNow,
            gaveUp: false, elapsedSinceStart: 320, corroborated: false, rebuildsExhausted: true,
        )
        XCTAssertEqual(
            monitor.update(
                ages: ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: window + 10),
                gaveUp: false, elapsedSinceStart: 430, corroborated: true, rebuildsExhausted: true,
            ),
            .digitalSilence,
        )
    }

    /// The flag reaches the monitor a queue hop and a poll after the watchdog
    /// decided, and the decision followed a process-state read of its own, so
    /// a far end that says a sentence in that gap leaves the flag stale before
    /// it is first seen. The watchdog gives up only on a run of zeros at least
    /// its trigger length long, so signal younger than that at first sight
    /// came after the give-up, and the later quiet is just quiet.
    func testAGiveUpFirstSeenWithSignalYoungerThanItsTriggerIsStale() {
        var monitor = ChannelFaultMonitor(window: window)
        let spokeInTheGap = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 5)
        XCTAssertNil(monitor.update(
            ages: spokeInTheGap, gaveUp: false, elapsedSinceStart: 300,
            corroborated: true, rebuildsExhausted: true,
        ))
        let quietSince = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 15)
        XCTAssertNil(monitor.update(
            ages: quietSince, gaveUp: false, elapsedSinceStart: 310,
            corroborated: true, rebuildsExhausted: true,
        ))
    }

    /// A tap that was never allowed to hear the app carries no signal at all
    /// (issue #524). "Never" is not "recently": its give-up stands.
    func testAChannelThatNeverCarriedSignalKeepsItsGiveUp() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertNil(monitor.update(
            ages: ChannelHealthHarness.silentSinceStart, gaveUp: false, elapsedSinceStart: 300,
            corroborated: false, rebuildsExhausted: true,
        ))
        XCTAssertEqual(
            monitor.update(
                ages: ChannelHealthHarness.silentSinceStart, gaveUp: false, elapsedSinceStart: 310,
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

        XCTAssertEqual(notifier.calls.filter { $0.body == watchdogBody }.count, 1)
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

        XCTAssertFalse(notifier.calls.contains { $0.body == watchdogBody })
        XCTAssertNotEqual(controller.appFault, .rebuildsExhausted)
    }

    /// The field order the stale report comes from: the watchdog gives up
    /// while the microphone is quiet, the far end then starts talking, and
    /// only after that does the local side speak.
    func testAGiveUpTheAppChannelRecoveredFromDoesNotReachTheUser() {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make(for: self)
        recorder.appLevelDBFS = -120
        recorder.micLevelDBFS = -120
        recorder.appSignalAges = deliveringSilence
        recorder.appSilentTrackWatchdogGaveUp = true
        for offset in stride(from: 0.0, through: 60.0, by: 10.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        recorder.appLevelDBFS = -20
        recorder.appSignalAges = .deliveringSignalNow
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(70))
        recorder.micLevelDBFS = -20
        for offset in stride(from: 80.0, through: 200.0, by: 10.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

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

        XCTAssertFalse(notifier.calls.contains { $0.body == watchdogBody })
        XCTAssertNotEqual(controller.appFault, .rebuildsExhausted)
    }
}
