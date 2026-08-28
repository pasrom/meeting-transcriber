import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Whether a capture channel is broken, which is a different question from
/// whether it is quiet.
///
/// `ChannelHealthIntegrationTests` covers the second: the asymmetric-silence
/// episodes that drive the menu-bar tint. This one covers the notifications,
/// which since issue #614 come from the buffer ages the capture layer records
/// rather than from those episodes. A microphone whose owner is listening
/// rather than talking is quiet, and telling them capture looks broken is the
/// habituating false alarm the change removes.
@MainActor
final class ChannelFaultIntegrationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let stoppedDelivering = ChannelHealthHarness.stoppedDelivering
    private let deliveringSilence = ChannelHealthHarness.deliveringSilence

    private func makeController() -> (ChannelHealthController, MockRecorder, RecordingNotifier, AppSettings) {
        ChannelHealthHarness.make()
    }

    // MARK: - Providers that do not simulate capture

    /// A recorder double that implements none of the optional reporting, i.e.
    /// takes every `RecordingProvider` default.
    private final class BareRecorder: RecordingProvider {
        func start(source _: RecordingSource, micDeviceUID _: String?, debugLogging _: Bool) {}
        func stop() -> RecordingResult {
            RecordingResult(
                mixPath: URL(fileURLWithPath: "/tmp/bare_mix.wav"),
                appPath: nil, micPath: nil, micDelay: 0, recordingStartDate: Date(),
            )
        }
    }

    func testAProviderThatDoesNotSimulateCaptureIsNeverReportedAsBroken() {
        // The protocol's defaults describe a healthy channel on purpose: a
        // double that says nothing about capture must not make a test in an
        // unrelated suite start posting capture-failure notifications. The
        // sibling `AudioCapturing` deliberately has no such default, because
        // there "said nothing" means "never opened".
        let (controller, _, notifier, _) = makeController()
        let bare = BareRecorder()

        for offset in stride(from: 0.0, through: 300.0, by: 10.0) {
            _ = controller.applyTick(recorder: bare, now: t0.addingTimeInterval(offset))
        }

        // Scoped to the capture titles on purpose. The same double also trips
        // "Recording Appears Silent", because the level defaults are -120 and
        // the symmetric monitor still decides from levels; that is untouched
        // here and asserting on it would pin behaviour this change does not own.
        let captureTitles = ["Capture Channel Silent", "Capture Channel Lost"]
        XCTAssertFalse(
            notifier.calls.contains { captureTitles.contains($0.title) },
            "reported: \(notifier.calls.map(\.title))",
        )
    }

    // MARK: - Focus / Do Not Disturb

    /// The whole escalation policy, on the pure functions. The test is not "how
    /// bad is this" but "does this have a benign reading": only the cases
    /// without one may interrupt a meeting in progress.
    func testOnlyCaptureFailuresWithoutABenignReadingBreakThroughFocus() {
        let cases: [(channel: AudioChannel, fault: ChannelFault, expected: NotificationUrgency)] = [
            // The far side does not go digitally silent while you are talking;
            // this is the case that cost an interview 59 minutes (issue #524).
            (.app, .digitalSilence, .timeSensitive),
            (.app, .noBuffers, .timeSensitive),
            // A mute switch on a headset is the likeliest cause, so this one
            // stays suppressible.
            (.mic, .digitalSilence, .standard),
            (.mic, .noBuffers, .timeSensitive),
        ]
        for row in cases {
            XCTAssertEqual(
                ChannelHealthController.captureAlert(channel: row.channel, fault: row.fault).urgency,
                row.expected,
                "channel=\(row.channel) fault=\(row.fault)",
            )
        }
    }

    func testAnAbandonedRestartAlwaysBreaksThroughFocus() {
        // The track is gone for the rest of the recording and only a restart
        // brings it back, on either channel.
        for channel in [AudioChannel.mic, .app] {
            XCTAssertEqual(
                ChannelHealthController.gaveUpAlert(channel: channel).urgency,
                .timeSensitive,
                "channel=\(channel)",
            )
            XCTAssertEqual(ChannelHealthController.gaveUpAlert(channel: channel).title, "Capture Channel Lost")
        }
    }

    // MARK: - What each fault tells the user to check

    func testTheFaultMessageDistinguishesTheChannel() {
        let appMessage = ChannelHealthController.faultMessage(channel: .app, fault: .noBuffers)
        let micMessage = ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers)
        XCTAssertNotEqual(appMessage, micMessage)
        XCTAssertTrue(appMessage.lowercased().contains("app-audio"))
        XCTAssertTrue(micMessage.lowercased().contains("microphone"))
    }

    func testTheAppFaultMessagePointsAtPermissionAndAudioTools() {
        // A far side that delivers nothing is most often a missing Screen &
        // System Audio Recording grant (the tap needs it) or a third-party audio
        // utility intercepting the meeting app's output (issue #524). Name both
        // so the notification is actionable instead of a dead end.
        for fault in [ChannelFault.noBuffers, .digitalSilence] {
            let message = ChannelHealthController.faultMessage(channel: .app, fault: fault)
            XCTAssertTrue(message.contains(SystemSettingsPaths.screenRecording), "\(fault)")
            XCTAssertTrue(message.contains("SoundSource"), "\(fault)")
        }
    }

    func testTheTwoMicFaultsSendTheUserToDifferentPlaces() {
        // A device that stopped answering and a device that is muted are
        // different things to go and fix.
        let stopped = ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers)
        let muted = ChannelHealthController.faultMessage(channel: .mic, fault: .digitalSilence)
        XCTAssertNotEqual(stopped, muted)
        XCTAssertTrue(muted.lowercased().contains("mute"))
        XCTAssertTrue(stopped.lowercased().contains("connected"))
    }

    // MARK: - Channel faults (issue #614)

    func testTheReportedFaultAndTheAgesBehindItStayReadable() {
        // The notification is fire-and-forget; the state is what a driver
        // script and a field diagnosis can actually look at, and it has to
        // carry both the verdict and the evidence for it.
        let (controller, recorder, _, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micSignalAges = deliveringSilence

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        XCTAssertEqual(controller.micFault, .digitalSilence)
        XCTAssertNil(controller.appFault)
        XCTAssertEqual(controller.micAges, deliveringSilence)
    }

    func testStopClearsTheReportedFault() {
        let (controller, recorder, _, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micSignalAges = stoppedDelivering

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertEqual(controller.micFault, .noBuffers)

        controller.stop()
        XCTAssertNil(controller.micFault)
    }

    func testAMicDeliveringNothingButZeroesIsReported() {
        // The device or macOS muted it. The transport is fine and the level is
        // the same -120 a dead tap reports, so only the ages can say which.
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micSignalAges = deliveringSilence

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls.first?.title, "Capture Channel Silent")
        XCTAssertEqual(
            notifier.calls.first?.body,
            ChannelHealthController.faultMessage(channel: .mic, fault: .digitalSilence),
        )
        // A mute switch is the likeliest cause, so this one stays suppressible.
        XCTAssertEqual(notifier.calls.first?.urgency, .standard)
    }

    func testAMicThatStoppedDeliveringIsReported() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micSignalAges = stoppedDelivering

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        XCTAssertEqual(
            notifier.calls.first?.body,
            ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers),
        )
        // Buffers stopping has no benign reading on either channel.
        XCTAssertEqual(notifier.calls.first?.urgency, .timeSensitive)
    }

    func testAMicDyingAfterASuppressedEpisodeIsStillReported() {
        // The reason the decision cannot live on the episode edge. The first
        // episode is correctly silent about a live-but-quiet microphone, and
        // the monitor will never start a second one: an episode ends only when
        // the silent side climbs back over the speech threshold, which a
        // channel that has since died can no longer do. Deciding at that edge
        // means a real failure after a suppressed one is never reported.
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -80

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertTrue(controller.micSilentActive, "the episode latched")
        XCTAssertTrue(notifier.calls.isEmpty, "and said nothing, correctly")

        // Now the microphone really stops.
        recorder.micLevelDBFS = -120
        recorder.micSignalAges = stoppedDelivering
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(40))

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(
            notifier.calls.first?.body,
            ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers),
        )
    }

    func testAChannelFaultIsReportedOncePerRecording() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micSignalAges = stoppedDelivering

        for offset in stride(from: 0.0, through: 300.0, by: 10.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        XCTAssertEqual(notifier.calls.count, 1, "reported: \(notifier.calls.map(\.title))")
    }

    func testTheSameChannelIsReportedAgainInTheNextRecording() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micSignalAges = stoppedDelivering

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        controller.stop()
        controller.simulateStartForTests()
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(100))
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(130))

        XCTAssertEqual(notifier.calls.count, 2)
    }

    func testAppChannelZeroesAreOnlyReportedWhileTheMicCarriesSpeech() {
        // Zeroes on the far side are also what a call with nobody talking looks
        // like. Without evidence that the recording is capturing anything, this
        // belongs to the symmetric-silence monitor.
        let (controller, recorder, notifier, _) = makeController()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -120
        recorder.appSignalAges = deliveringSilence

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertFalse(
            notifier.calls.contains { $0.title == "Capture Channel Silent" },
            "nobody was speaking, so nothing proves the tap should be carrying anything",
        )

        // The user starts talking: now the far side's silence is a fault.
        recorder.micLevelDBFS = -20
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(40))

        XCTAssertEqual(
            notifier.calls.filter { $0.title == "Capture Channel Silent" }.count, 1,
        )
        XCTAssertEqual(notifier.calls.last?.urgency, .timeSensitive)
    }

    // MARK: - Capture give-up (issue #588)

    func testASilentChannelThatGaveUpGetsTheRestartMessage() {
        // A channel that merely fell silent may come back. One whose restart
        // attempt was abandoned will not, and the wedged attempt keeps burning
        // CPU until the app restarts, so the user must be told something else.
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micCaptureGaveUp = true

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(
            notifier.calls.first?.body,
            ChannelHealthController.captureGaveUpMessage(for: .mic),
        )
    }

    func testASilentChannelThatDidNotGiveUpIsToldWhatToCheck() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micSignalAges = stoppedDelivering

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        XCTAssertEqual(
            notifier.calls.first?.body,
            ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers),
        )
    }

    func testTheGiveUpMessageRecommendsARestart() {
        // The leaked thread only goes away with the process, so the advice has to
        // say so; "check your mic" would send the user chasing the wrong thing.
        let message = ChannelHealthController.captureGaveUpMessage(for: .mic)
        XCTAssertTrue(message.lowercased().contains("restart"))
        XCTAssertNotEqual(message, ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers))
    }

    func testGaveUpAfterALatchedEpisodeStillNotifiesLost() {
        // The give-up flag is only meaningful the moment it flips, and it can
        // flip at any point in a recording. Reading it solely while an
        // asymmetric episode starts means a channel that gives up *after* the
        // episode latched is never reported: the episode fired already, and the
        // monitor cannot start a second one because recovery needs the dead
        // channel to climb back over the speech threshold, which is exactly
        // what a channel that gave up will never do.
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertTrue(notifier.calls.isEmpty, "a live channel that is merely quiet says nothing")

        recorder.micCaptureGaveUp = true
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(31))
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(60))

        XCTAssertEqual(
            notifier.calls.filter { $0.title == "Capture Channel Lost" }.count, 1,
            "giving up after the latch must still reach the user, and only once",
        )
    }

    func testGaveUpDuringSymmetricSilenceNotifiesLost() {
        // Second way the flag is missed today: with both channels quiet there is
        // no asymmetry, so no episode ever starts, so nothing reads the flag.
        // A give-up is a terminal capture failure whether or not the other
        // channel happens to be carrying speech at that moment.
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -120
        recorder.micLevelDBFS = -120
        recorder.micCaptureGaveUp = true

        controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        XCTAssertEqual(
            notifier.calls.filter { $0.title == "Capture Channel Lost" }.count, 1,
            "a terminal capture failure does not depend on the other channel",
        )
    }

    func testGaveUpNotifiesWithoutWaitingForTheDebounce() {
        // The give-up is already terminal when the flag flips; making the user
        // wait out the asymmetry debounce for news that cannot change is the
        // same defect as not telling them at all, only quieter.
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micCaptureGaveUp = true

        controller.applyTick(recorder: recorder, now: t0)
        XCTAssertEqual(
            notifier.calls.filter { $0.title == "Capture Channel Lost" }.count, 1,
            "the first tick that sees the flag reports it",
        )

        for offset in stride(from: 10.0, through: 90.0, by: 10.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        XCTAssertEqual(
            notifier.calls.filter { $0.title == "Capture Channel Lost" }.count, 1,
            "and it stays at one for the rest of the recording",
        )
    }

    func testGaveUpNotifiesAgainOnTheNextRecording() {
        // The latch is per recording, not per process: a restart that fails the
        // same way in the next meeting has to say so again.
        let (controller, recorder, notifier, _) = makeController()
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micCaptureGaveUp = true

        controller.applyTick(recorder: recorder, now: t0)
        controller.stop()
        controller.simulateStartForTests()
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(120))

        XCTAssertEqual(notifier.calls.filter { $0.title == "Capture Channel Lost" }.count, 2)
    }
}
