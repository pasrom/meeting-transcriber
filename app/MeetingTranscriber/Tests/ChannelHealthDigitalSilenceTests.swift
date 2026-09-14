import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The rolling-sample verdict arrives windowed by the capture layer. It must
/// not wait for microphone speech or a second debounce, and shares the existing
/// app-fault notification policy rather than opening a parallel alert path.
@MainActor
final class ChannelHealthDigitalSilenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeController() -> (ChannelHealthController, MockRecorder, RecordingNotifier) {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make()
        return (controller, recorder, notifier)
    }

    func testFlagIsInactiveByDefault() {
        let (controller, _, _) = makeController()
        XCTAssertFalse(controller.appDigitalSilenceActive)
    }

    /// The whole point: one tick, no debounce, no speech on the other channel.
    func testDigitalSilenceIsReportedOnTheFirstTick() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        // Both channels quiet — the shape that kept the asymmetric monitor from
        // ever confirming during the incident.
        recorder.micLevelDBFS = -120
        recorder.appLevelDBFS = -120
        recorder.appCaptureDigitallySilent = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertTrue(controller.appDigitalSilenceActive)
        XCTAssertEqual(controller.appFault, .digitalSilence)
        XCTAssertEqual(controller.appAges, recorder.appSignalAges, "native ages must not be replaced by inferred ones")
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls.first?.title, "Capture Channel Silent")
        XCTAssertEqual(notifier.calls.first?.body, ChannelHealthController.digitalSilenceMessage)
        XCTAssertEqual(notifier.calls.first?.urgency, .timeSensitive)
    }

    func testDigitalSilenceTintsTheAppHalfOfTheMenuBar() {
        let (controller, recorder, _) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertTrue(controller.appSilentOverlay)
        XCTAssertFalse(controller.micSilentOverlay)
    }

    /// A microphone-only recording has no app channel, so its permanently
    /// absent tap must not paint anything.
    func testDigitalSilenceIsSuppressedOnARecordingWithNoAppChannel() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests(channels: .micOnly)
        recorder.appCaptureDigitallySilent = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertFalse(controller.appSilentOverlay)
        XCTAssertFalse(controller.appDigitalSilenceActive)
        XCTAssertNil(controller.appFault)
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testDigitalSilenceIsReportedOncePerEpisode() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true

        for offset in stride(from: 0.0, through: 300.0, by: 0.1) {
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        XCTAssertEqual(notifier.calls.count, 1, "neither polling nor symmetric silence should duplicate the app fault")
        XCTAssertTrue(controller.recordingSilentActive, "suppressing duplicate alerts must not suppress the tint")
    }

    func testRecoveryClearsTheFlagWithoutANotification() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true
        controller.applyTick(recorder: recorder, now: t0)
        XCTAssertTrue(controller.appDigitalSilenceActive)

        recorder.appCaptureDigitallySilent = false
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(1))

        XCTAssertFalse(controller.appDigitalSilenceActive)
        XCTAssertFalse(controller.appSilentOverlay)
        XCTAssertEqual(controller.appFault, .digitalSilence, "the reported fault remains recording history")
        XCTAssertEqual(notifier.calls.count, 1, "recovery is not worth a second alert")
    }

    func testASecondEpisodePreservesTheOncePerRecordingSilencePolicy() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()

        recorder.appCaptureDigitallySilent = true
        controller.applyTick(recorder: recorder, now: t0)
        recorder.appCaptureDigitallySilent = false
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(1))
        recorder.appCaptureDigitallySilent = true
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(2))

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(controller.appSilentOverlay)
    }

    func testStopClearsTheFlag() {
        let (controller, recorder, _) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true
        controller.applyTick(recorder: recorder, now: t0)

        controller.stop()

        XCTAssertFalse(controller.appDigitalSilenceActive)
        XCTAssertFalse(controller.appSilentOverlay)
        XCTAssertNil(controller.appFault)
    }

    func testNewRecordingClearsTheVerdictAndAllowsANewReport() {
        for stopFirst in [true, false] {
            let (controller, recorder, notifier) = makeController()
            controller.simulateStartForTests()
            recorder.appCaptureDigitallySilent = true
            controller.applyTick(recorder: recorder, now: t0)

            if stopFirst { controller.stop() }
            controller.simulateStartForTests()

            XCTAssertFalse(controller.appDigitalSilenceActive)
            XCTAssertFalse(controller.appSilentOverlay)
            XCTAssertNil(controller.appFault)
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(1))
            XCTAssertEqual(notifier.calls.count, 2)
        }
    }

    func testDisablingTheIndicatorDoesNotDisableTheFaultNotification() {
        let (controller, recorder, notifier, settings) = ChannelHealthHarness.make()
        settings.perChannelIndicatorEnabled = false
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertTrue(controller.appDigitalSilenceActive)
        XCTAssertFalse(controller.appSilentOverlay)
        XCTAssertEqual(notifier.calls.count, 1)
    }

    func testMessageNamesPossibleRoutingMismatchWithoutPromisingARetry() {
        let message = ChannelHealthController.digitalSilenceMessage
        XCTAssertTrue(message.contains("mostly digital silence"))
        XCTAssertTrue(message.contains("meeting app's output selection"))
        XCTAssertTrue(message.contains(SystemSettingsPaths.soundOutput))
        XCTAssertTrue(message.contains("may be using different output devices"))
        XCTAssertTrue(message.contains("limited retry budget"))
        XCTAssertTrue(message.contains("may have stopped trying"))
        XCTAssertFalse(message.contains("pure silence"))
        XCTAssertFalse(message.contains("while the microphone"))
    }

    /// A low level alone cannot establish the rolling-sample verdict.
    func testQuietChannelsAloneDoNotTriggerDigitalSilence() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.micLevelDBFS = -120
        recorder.appLevelDBFS = -61.3

        for offset in stride(from: 0.0, through: 300.0, by: 1.0) {
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        XCTAssertFalse(controller.appDigitalSilenceActive)
        XCTAssertNil(controller.appFault)
        XCTAssertTrue(
            notifier.calls.allSatisfy { $0.title != "Capture Channel Silent" },
        )
    }

    func testTheRollingAndAgeBasedDigitalSilenceVerdictsDoNotDuplicateNotifications() {
        for rollingFirst in [true, false] {
            let (controller, recorder, notifier) = makeController()
            controller.simulateStartForTests()
            recorder.micLevelDBFS = -20
            recorder.appSignalAges = ChannelHealthHarness.deliveringSilence
            recorder.appCaptureDigitallySilent = rollingFirst

            controller.applyTick(recorder: recorder, now: t0)
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
            recorder.appCaptureDigitallySilent = true
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(31))

            XCTAssertEqual(notifier.calls.count, 1, "rollingFirst=\(rollingFirst)")
            XCTAssertEqual(controller.appFault, .digitalSilence)
            XCTAssertTrue(controller.appDigitalSilenceActive)
        }
    }

    func testNoBuffersTakesPrecedenceWhenBothVerdictsArriveTogether() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.micLevelDBFS = -20
        controller.applyTick(recorder: recorder, now: t0)
        recorder.appCaptureDigitallySilent = true
        recorder.appSignalAges = ChannelHealthHarness.stoppedDelivering

        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(31))

        XCTAssertEqual(controller.appFault, .noBuffers)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(
            notifier.calls.first?.body,
            ChannelHealthController.faultMessage(channel: .app, fault: .noBuffers, everCarriedSignal: true),
        )
    }

    func testNoBuffersAndRollingSilenceShareAReportButGiveUpStillEscalates() {
        for rollingFirst in [true, false] {
            let (controller, recorder, notifier) = makeController()
            controller.simulateStartForTests()
            recorder.micLevelDBFS = -20
            recorder.appCaptureDigitallySilent = rollingFirst
            controller.applyTick(recorder: recorder, now: t0)

            recorder.appSignalAges = ChannelHealthHarness.stoppedDelivering
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
            recorder.appCaptureDigitallySilent = true
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(31))
            XCTAssertEqual(notifier.calls.count, 1)

            recorder.appCaptureGaveUp = true
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(32))
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(33))

            XCTAssertEqual(controller.appFault, .gaveUp)
            XCTAssertEqual(notifier.calls.map(\.title), ["Capture Channel Silent", "Capture Channel Lost"])
            XCTAssertEqual(notifier.calls.last?.body, ChannelHealthController.captureGaveUpMessage(for: .app))
            XCTAssertEqual(notifier.calls.last?.urgency, .timeSensitive)
        }
    }

    func testGiveUpPreemptsRollingSilenceAndIsNeverDowngraded() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureGaveUp = true
        recorder.appCaptureDigitallySilent = true

        controller.applyTick(recorder: recorder, now: t0)
        recorder.appSignalAges = ChannelHealthHarness.stoppedDelivering
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        XCTAssertEqual(controller.appFault, .gaveUp)
        XCTAssertEqual(notifier.calls.map(\.title), ["Capture Channel Lost"])
    }

    func testRollingAppSilenceDoesNotSuppressAMicrophoneFault() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true
        recorder.micSignalAges = ChannelHealthHarness.stoppedDelivering

        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        XCTAssertEqual(controller.appFault, .digitalSilence)
        XCTAssertEqual(controller.micFault, .noBuffers)
        XCTAssertEqual(notifier.calls.count, 2)
    }
}
