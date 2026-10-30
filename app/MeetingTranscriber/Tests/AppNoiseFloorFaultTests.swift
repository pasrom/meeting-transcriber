import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// What the user hears when the app-audio tap carries only a level below one
/// 16-bit step (issue #699): one "Capture Channel Silent" notification, through
/// the same fault monitor, corroboration and once-per-recording silence latch
/// as digital silence. The sensor itself is pinned in AudioTapLib.
///
/// Such a channel delivers buffers that carry energy, so its ages read as a
/// healthy channel's (`deliveringSignalNow`); only the sensor's flag says
/// otherwise.
@MainActor
final class AppNoiseFloorFaultTests: XCTestCase {
    private let window: TimeInterval = 90
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let floorAges = ChannelSignalAges.deliveringSignalNow

    // MARK: - The monitor

    func testTheFloorIsReportedOnceTheWindowHasPassedAndOnce() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertNil(monitor.update(
            ages: floorAges, gaveUp: false, elapsedSinceStart: window - 1, corroborated: true, noiseFloor: true,
        ))
        XCTAssertEqual(
            monitor.update(ages: floorAges, gaveUp: false, elapsedSinceStart: window, corroborated: true, noiseFloor: true),
            .noiseFloor,
        )
        XCTAssertNil(monitor.update(
            ages: floorAges, gaveUp: false, elapsedSinceStart: 600, corroborated: true, noiseFloor: true,
        ))
    }

    /// A far end that is muted or on hold is no reason to interrupt anyone,
    /// so like digital silence it waits for the microphone to show the call is
    /// live, and reports as soon as it does.
    func testItWaitsForTheMicrophoneToCorroborate() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertNil(monitor.update(
            ages: floorAges, gaveUp: false, elapsedSinceStart: 300, corroborated: false, noiseFloor: true,
        ))
        XCTAssertEqual(
            monitor.update(ages: floorAges, gaveUp: false, elapsedSinceStart: 310, corroborated: true, noiseFloor: true),
            .noiseFloor,
        )
    }

    func testAChannelWithoutTheFlagIsNotReported() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertNil(monitor.update(ages: floorAges, gaveUp: false, elapsedSinceStart: 600, corroborated: true))
    }

    /// One silence report per channel and recording: a floor and exact zeros
    /// are two shapes of the same "nothing is reaching this track".
    func testAFloorAfterADigitalSilenceReportIsNotReported() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(
            monitor.update(
                ages: ChannelHealthHarness.deliveringSilence, gaveUp: false, elapsedSinceStart: 300, corroborated: true,
            ),
            .digitalSilence,
        )
        XCTAssertNil(monitor.update(
            ages: floorAges, gaveUp: false, elapsedSinceStart: 400, corroborated: true, noiseFloor: true,
        ))
    }

    func testDigitalSilenceAfterAFloorReportIsNotReported() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(
            monitor.update(ages: floorAges, gaveUp: false, elapsedSinceStart: 300, corroborated: true, noiseFloor: true),
            .noiseFloor,
        )
        XCTAssertNil(monitor.update(
            ages: ChannelHealthHarness.deliveringSilence, gaveUp: false, elapsedSinceStart: 400, corroborated: true,
        ))
    }

    /// The watchdog report already said this channel records only silence and
    /// that rebuilding did not help; a floor report after it says less.
    func testAFloorAfterTheWatchdogGaveUpIsNotReported() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(
            monitor.update(
                ages: ChannelHealthHarness.deliveringSilence, gaveUp: false, elapsedSinceStart: 300,
                corroborated: true, rebuildsExhausted: true,
            ),
            .rebuildsExhausted,
        )
        XCTAssertNil(monitor.update(
            ages: floorAges, gaveUp: false, elapsedSinceStart: 400, corroborated: true,
            rebuildsExhausted: true, noiseFloor: true,
        ))
    }

    /// The sensor's flag holds while no buffer arrives to move it. Buffers
    /// stopping is the more specific news and keeps its own message.
    func testBuffersStoppingWinOverAFloorVerdictLeftStanding() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(
            monitor.update(
                ages: ChannelHealthHarness.stoppedDelivering, gaveUp: false, elapsedSinceStart: 600,
                corroborated: true, noiseFloor: true,
            ),
            .noBuffers,
        )
    }

    /// A window of exact zeros counts for the sensor too. Exact silence keeps
    /// its own report, whose message can tell a denied tap from a dead one.
    func testExactSilenceKeepsItsOwnReport() {
        var monitor = ChannelFaultMonitor(window: window)
        XCTAssertEqual(
            monitor.update(
                ages: ChannelHealthHarness.deliveringSilence, gaveUp: false, elapsedSinceStart: 300,
                corroborated: true, noiseFloor: true,
            ),
            .digitalSilence,
        )
    }

    /// The sensor counts exact zeros too. With a Warn-after above its window,
    /// a stretch of exact zeros trips the sensor before the digital-silence
    /// window has passed; it must stay that report's, whose message can tell
    /// a denied tap from a dead one, not become a floor report that latches
    /// it out.
    func testExactZerosUnderALongWarnAfterAreLeftToDigitalSilence() {
        var monitor = ChannelFaultMonitor(window: 300)
        let zerosFor200s = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 200)
        XCTAssertNil(monitor.update(
            ages: zerosFor200s, gaveUp: false, elapsedSinceStart: 400, corroborated: true, noiseFloor: true,
        ))
        let zerosFor300s = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 300)
        XCTAssertEqual(
            monitor.update(ages: zerosFor300s, gaveUp: false, elapsedSinceStart: 500, corroborated: true, noiseFloor: true),
            .digitalSilence,
        )
    }

    /// The same long Warn-after with a real floor: a non-zero sample inside
    /// the sensor's window, so it is the floor's report. The edge is the
    /// sensor's window itself.
    func testAFloorUnderALongWarnAfterIsStillReported() {
        let window = AppNoiseFloorLimits.windowSeconds
        var inside = ChannelFaultMonitor(window: 300)
        XCTAssertEqual(
            inside.update(
                ages: ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: window - 1),
                gaveUp: false, elapsedSinceStart: 400, corroborated: true, noiseFloor: true,
            ),
            .noiseFloor,
        )
        var atTheEdge = ChannelFaultMonitor(window: 300)
        XCTAssertNil(atTheEdge.update(
            ages: ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: window),
            gaveUp: false, elapsedSinceStart: 400, corroborated: true, noiseFloor: true,
        ))
    }

    // MARK: - The copy

    func testTheAlertIsSilentNotLostAndPiercesFocus() {
        let alert = ChannelHealthController.captureAlert(channel: .app, fault: .noiseFloor, everCarriedSignal: true)
        XCTAssertEqual(alert.title, "Capture Channel Silent")
        XCTAssertEqual(alert.urgency, .timeSensitive)
    }

    /// What to do and where, first. Not the permission pane: a tap that is
    /// not allowed to hear the app delivers exact zeros (issue #524), not a
    /// floor.
    func testTheBodyNamesTheRemedyAndNotThePermission() {
        let body = ChannelHealthController.faultMessage(channel: .app, fault: .noiseFloor, everCarriedSignal: true)
        XCTAssertTrue(body.contains("Control Center"), body)
        XCTAssertTrue(body.contains(SystemSettingsPaths.soundOutput), body)
        XCTAssertTrue(body.contains("the device the meeting app plays through"), body)
        XCTAssertFalse(body.contains(SystemSettingsPaths.screenRecording), body)
        XCTAssertFalse(body.contains("Restart Meeting Transcriber"), "the channel did not stop")
    }

    // MARK: - Through the controller

    private func makeFloorRecording() -> (ChannelHealthController, MockRecorder, RecordingNotifier) {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make(for: self)
        controller.simulateStartForTests()
        recorder.appLevelDBFS = -98.5
        recorder.micLevelDBFS = -20
        recorder.appSignalAges = floorAges
        recorder.appCarriesOnlyNoiseFloor = true
        return (controller, recorder, notifier)
    }

    private func tick(_ controller: ChannelHealthController, _ recorder: MockRecorder, through seconds: TimeInterval) {
        for offset in stride(from: 0.0, through: seconds, by: 10.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }
    }

    private var floorBody: String {
        ChannelHealthController.faultMessage(channel: .app, fault: .noiseFloor, everCarriedSignal: true)
    }

    func testAFloorReachesTheUserOnceThroughTheController() {
        let (controller, recorder, notifier) = makeFloorRecording()
        tick(controller, recorder, through: 300)

        XCTAssertEqual(notifier.calls.filter { $0.body == floorBody }.count, 1)
        XCTAssertEqual(controller.appFault, .noiseFloor)
        XCTAssertNil(controller.micFault)
    }

    func testAFloorWithASilentMicrophoneIsNotReported() {
        let (controller, recorder, notifier) = makeFloorRecording()
        recorder.micLevelDBFS = -120
        tick(controller, recorder, through: 300)

        XCTAssertFalse(notifier.calls.contains { $0.body == floorBody })
        XCTAssertNil(controller.appFault)
    }

    /// The floor rule is the app channel's alone. With both channels carrying
    /// speech the microphone is corroborated, so handing it the app's flag
    /// would report the microphone too.
    func testTheAppsFloorVerdictNeverFaultsTheMicrophone() {
        let (controller, recorder, _) = makeFloorRecording()
        recorder.appLevelDBFS = -20
        tick(controller, recorder, through: 300)

        XCTAssertNil(controller.micFault)
    }

    /// The live reading, which `/state` reports beside the latched fault.
    func testTheLiveFlagFollowsTheSensorAndEndsWithTheRecording() {
        let (controller, recorder, _) = makeFloorRecording()
        controller.applyTick(recorder: recorder, now: t0)
        XCTAssertTrue(controller.appNoiseFloorOnly)

        recorder.appCarriesOnlyNoiseFloor = false
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(1))
        XCTAssertFalse(controller.appNoiseFloorOnly)

        recorder.appCarriesOnlyNoiseFloor = true
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(2))
        controller.stop()
        XCTAssertFalse(controller.appNoiseFloorOnly)
    }
}
