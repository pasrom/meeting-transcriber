import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Integration test of the `ChannelHealthController` polling-tick path: drives
/// `applyTick` against a mock recorder with controllable per-channel levels and
/// verifies the observable flags + notification side-effects line up with the
/// `ChannelHealthMonitor` events.
///
/// Constructs a bare `ChannelHealthController` (not a full `AppState`) — the
/// controller was extracted from AppState precisely so this concern is testable
/// in isolation, against settings closures + a mock recorder, without a
/// `WatchLoop` or the rest of the app.
///
/// Covers the production scenario "user mutes their mic while the meeting app's
/// audio continues to play other participants" — the mic input goes to -120 dBFS,
/// the app-audio CATapDescription channel keeps reporting speech levels, and the
/// indicator must fire `.started(.mic)` after the configured debounce.
@MainActor
final class ChannelHealthIntegrationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private let stoppedDelivering = ChannelHealthHarness.stoppedDelivering

    private func makeController() -> (ChannelHealthController, MockRecorder, RecordingNotifier, AppSettings) {
        ChannelHealthHarness.make()
    }

    // MARK: - Defaults

    func testFlagsInactiveByDefault() {
        let (controller, _, _, _) = makeController()
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)
        XCTAssertFalse(controller.recordingSilentActive)
    }

    // MARK: - Production scenario: user mutes their mic mid-meeting

    func testAQuietButLiveMicTintsWithoutNotifying() {
        let (controller, recorder, notifier, _) = makeController()
        // Initialize monitor with the same debounce as production start().
        // (The test bypasses the polling task; we still need a fresh monitor.)
        controller.applyTick(recorder: recorder, now: t0) // warmup tick

        recorder.micLevelDBFS = -80 // muted
        recorder.appLevelDBFS = -25 // other participants speaking

        // Before debounce elapses: nothing fires
        _ = controller.applyTick(recorder: recorder, now: t0)
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)
        XCTAssertEqual(notifier.calls.count, 0)

        // At the debounce boundary the tint latches, and that is all. The mic
        // is delivering real buffers at -80 dBFS: someone listening in a quiet
        // room, or muted in the meeting app, which does not touch our own
        // capture. Issue #614 is about this notification, which is now absent.
        let event = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertEqual(event, .started(channel: .mic, quietSince: t0))
        XCTAssertTrue(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)
        XCTAssertTrue(notifier.calls.isEmpty, "reported: \(notifier.calls.map(\.title))")
    }

    func testAQuietButLiveAppChannelTintsWithoutNotifying() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.micLevelDBFS = -25 // user speaking
        recorder.appLevelDBFS = -80 // app audio dead (e.g. dropped CATapDescription)

        _ = controller.applyTick(recorder: recorder, now: t0)
        let event = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertEqual(event, .started(channel: .app, quietSince: t0))
        XCTAssertTrue(controller.appSilentActive)
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertTrue(notifier.calls.isEmpty, "reported: \(notifier.calls.map(\.title))")
    }

    // MARK: - Latch + recovery

    func testStartedFiresExactlyOncePerEpisode() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25

        _ = controller.applyTick(recorder: recorder, now: t0)
        let started = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertEqual(started, .started(channel: .mic, quietSince: t0))

        // Subsequent ticks while the episode is latched must not re-fire.
        XCTAssertNil(controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(40)))
        XCTAssertNil(controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(120)))
        XCTAssertTrue(controller.micSilentActive)
        XCTAssertTrue(notifier.calls.isEmpty, "the episode drives the tint, not the notifier")
    }

    func testRecoveryClearsBothFlags() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25

        _ = controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30)) // .started
        XCTAssertTrue(controller.micSilentActive)

        // Mic comes back online (user unmutes).
        recorder.micLevelDBFS = -25
        let event = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(40))
        XCTAssertEqual(event, .recovered(channel: .mic))
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)
        XCTAssertTrue(notifier.calls.isEmpty, "a live channel going quiet and coming back is not a fault")
    }

    // MARK: - Channel switch mid-episode

    func testChannelSwitchClearsOldFlagBeforeNewFires() {
        let (controller, recorder, notifier, _) = makeController()
        // Phase 1: mic silent, app speaking — start tracking mic
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25
        _ = controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30)) // mic .started
        XCTAssertTrue(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)

        // Phase 2: roles flip — mic recovers AND app dies. Monitor's channel-switch path resets.
        recorder.micLevelDBFS = -25
        recorder.appLevelDBFS = -80
        // Right at the swap: not asymmetric in the same direction → monitor returns to clean state.
        // Both flags clear via `.recovered`.
        let recovery = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(35))
        XCTAssertEqual(recovery, .recovered(channel: .mic))
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)

        // Phase 3: app stays dead, mic stays alive — new episode tracks app
        let event = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(65))
        XCTAssertEqual(event, .started(channel: .app, quietSince: t0.addingTimeInterval(35)))
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertTrue(controller.appSilentActive)
        XCTAssertTrue(notifier.calls.isEmpty, "both channels were delivering throughout")
    }

    // MARK: - Symmetric cases never fire

    func testBothChannelsActiveDoesNotFire() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.micLevelDBFS = -25
        recorder.appLevelDBFS = -25
        for offset in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)
        XCTAssertEqual(notifier.calls.count, 0)
    }

    func testBothChannelsSilentDoesNotFireAsymmetricFlags() {
        // Asymmetric monitor must NOT treat symmetric silence as an event
        // (its job is one-side-dead detection). The sibling
        // `SilentRecordingMonitor` *does* fire on this case — see
        // `testBothChannelsSilentFiresRecordingSilentAfterDebounce`.
        let (controller, recorder, _, _) = makeController()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -80
        for offset in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)
    }

    // MARK: - Silent-recording (symmetric silence) detection

    func testBothChannelsSilentFiresRecordingSilentAfterDebounce() {
        // Sibling-monitor coverage of the 40-minute zero-audio failure
        // mode that shipped past PR #286: both channels at the noise
        // floor for the entire recording, no in-app warning. The new
        // `SilentRecordingMonitor` shares the same debounce as
        // `ChannelHealthMonitor` and fires `recordingSilentActive` plus
        // a notification.
        let (controller, recorder, notifier, _) = makeController()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -80
        _ = controller.applyTick(recorder: recorder, now: t0)
        XCTAssertFalse(controller.recordingSilentActive)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertTrue(controller.recordingSilentActive)
        // Asymmetric flags stay clear — semantics distinct from the
        // mic/app-silent path.
        XCTAssertFalse(controller.micSilentActive)
        XCTAssertFalse(controller.appSilentActive)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "Recording Appears Silent")
        // Suppressible on purpose: a waiting room looks exactly like this.
        XCTAssertEqual(notifier.calls.first?.urgency, .standard)
    }

    func testRecordingSilentRecoversWhenAnyChannelReturnsToSpeech() {
        let (controller, recorder, _, _) = makeController()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -80
        _ = controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertTrue(controller.recordingSilentActive)

        recorder.micLevelDBFS = -25
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(35))
        XCTAssertFalse(controller.recordingSilentActive)
    }

    // MARK: - Settings re-init across recordings

    func testThresholdChangeBetweenRecordingsTakesEffectOnNextStart() {
        let (controller, recorder, _, settings) = makeController()
        // First recording uses the initial 30 s debounce; warm-up tick.
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25
        _ = controller.applyTick(recorder: recorder, now: t0)
        XCTAssertNil(
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(20)),
            "20s under initial 30s debounce should not fire yet",
        )

        // User stops watching → would normally call stop(), then bumps the
        // threshold up to 60s before starting again.
        settings.asymmetricSilenceWarningSeconds = 60
        controller.simulateStartForTests()

        // Replay the same asymmetric levels — but now 30s should NOT be enough.
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(100))
        XCTAssertNil(
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(140)),
            "40s under new 60s debounce should not fire — proves the monitor picked up the new threshold",
        )
        let event = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(160))
        XCTAssertEqual(
            event,
            .started(channel: .mic, quietSince: t0.addingTimeInterval(100)),
            "60s under new threshold should fire — confirms threshold = 60",
        )
    }

    // MARK: - stop() teardown

    func testStopClearsLatchedMicSilentFlagAndResetsMonitor() {
        let (controller, recorder, _, _) = makeController()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25
        _ = controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30)) // mic .started
        XCTAssertTrue(controller.micSilentActive, "precondition: mic-silent is latched")

        controller.stop()
        XCTAssertFalse(controller.micSilentActive, "stop() must clear the latched mic-silent flag")
        XCTAssertFalse(controller.appSilentActive)
        XCTAssertFalse(controller.recordingSilentActive)

        // Monitor was reset: replaying the same silence needs a FRESH full
        // debounce before it re-fires (a non-reset monitor stays latched and
        // never re-fires the .started event).
        let t1 = t0.addingTimeInterval(200)
        _ = controller.applyTick(recorder: recorder, now: t1) // warmup on the fresh monitor
        let reFired = controller.applyTick(recorder: recorder, now: t1.addingTimeInterval(30))
        XCTAssertEqual(
            reFired, .started(channel: .mic, quietSince: t1),
            "a reset monitor starts a new episode and re-fires after a full debounce",
        )
        XCTAssertTrue(controller.micSilentActive)
    }

    func testStopClearsLatchedRecordingSilentFlagAndResetsSiblingMonitor() {
        let (controller, recorder, _, _) = makeController()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -80
        _ = controller.applyTick(recorder: recorder, now: t0)
        _ = controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertTrue(controller.recordingSilentActive, "precondition: symmetric-silence is latched")

        controller.stop()
        XCTAssertFalse(controller.recordingSilentActive, "stop() must clear the latched recording-silent flag")

        // The sibling SilentRecordingMonitor is reset too: a fresh silent window
        // re-fires after a full debounce (a non-reset monitor stays latched).
        let t1 = t0.addingTimeInterval(200)
        _ = controller.applyTick(recorder: recorder, now: t1)
        _ = controller.applyTick(recorder: recorder, now: t1.addingTimeInterval(30))
        XCTAssertTrue(controller.recordingSilentActive, "reset sibling monitor re-fires on a fresh silent window")
    }

    // MARK: - Microphone-only recordings (issue #633)

    func testMicrophoneOnlyRecordingRaisesNoDeadAppChannelAlert() {
        // The whole point of the fix. Before it this sequence produced a
        // `.timeSensitive` notification, one that deliberately pierces Focus,
        // telling the user to enable Screen Recording for a recording that
        // never wanted a tap.
        let (controller, recorder, notifier, _) = makeController()
        controller.simulateStartForTests(channels: .micOnly)
        recorder.micLevelDBFS = -20
        recorder.appLevelDBFS = -120

        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(600))

        XCTAssertTrue(notifier.calls.isEmpty, "reported: \(notifier.calls.map(\.title))")
        XCTAssertFalse(controller.appSilentActive)
    }

    /// Drives the real `start(source:)` rather than the `simulateStartForTests`
    /// seam, because that seam was the only thing the topology assertions went
    /// through — the production entry point that reads `source.capturedChannels`
    /// had no coverage at all, and it is the one that has to be right.
    func testTheProductionStartWiresTheTopologyFromTheSource() {
        let (controller, recorder, notifier, _) = makeController()
        recorder.micLevelDBFS = -20
        recorder.appLevelDBFS = -120
        controller.start(source: .micOnly) { recorder }
        defer { controller.stop() }

        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(600))

        XCTAssertTrue(notifier.calls.isEmpty, "reported: \(notifier.calls.map(\.title))")
        XCTAssertFalse(controller.appSilentOverlay)
    }

    func testAMicrophoneOnlyRecordingDoesNotSuppressTheNextDualSourceOne() {
        // The topology is per-recording, and the one that matters is the one
        // the *current* start declared. Asserted through the production entry
        // point both times, because that is what carries the value.
        let (controller, recorder, notifier, _) = makeController()
        controller.start(source: .micOnly) { recorder }
        controller.stop()

        controller.start(source: .appAndMic(pid: 1)) { recorder }
        defer { controller.stop() }
        recorder.micLevelDBFS = -20
        recorder.appLevelDBFS = -120
        recorder.appSignalAges = stoppedDelivering
        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(600))

        XCTAssertEqual(notifier.calls.first?.title, "Capture Channel Silent")
        XCTAssertTrue(controller.appSilentOverlay)
    }

    func testTheSameLevelsStillAlertWhenTheAppChannelWasOpened() {
        // Control case: identical levels and timing, only the topology differs.
        // Without it the assertion above would also pass on a controller that
        // had stopped alerting altogether.
        let (controller, recorder, notifier, _) = makeController()
        controller.simulateStartForTests()
        recorder.micLevelDBFS = -20
        recorder.appLevelDBFS = -120
        recorder.appSignalAges = stoppedDelivering

        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(600))

        XCTAssertEqual(notifier.calls.first?.title, "Capture Channel Silent")
        XCTAssertTrue(controller.appSilentActive)
    }

    func testMicrophoneOnlyRecordingNeverTintsTheAppHalfOfTheIcon() {
        // Symmetric silence paints both halves. With no app channel the bottom
        // half would claim a dead tap that does not exist.
        let (controller, recorder, _, _) = makeController()
        controller.simulateStartForTests(channels: .micOnly)
        recorder.micLevelDBFS = -120
        recorder.appLevelDBFS = -120

        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(600))

        XCTAssertTrue(controller.recordingSilentActive, "a silent mic-only recording is still silent")
        XCTAssertTrue(controller.micSilentOverlay)
        XCTAssertFalse(controller.appSilentOverlay, "there is no app channel to paint")
    }

    func testASilentAppOnlyRecordingIsNotToldToCheckAMicrophoneItNeverOpened() {
        // With "No Microphone" the mic reads a permanent -120, so symmetric
        // silence fires on any silent app track — and the dual-source wording
        // sends the user after an input device the recording never touched.
        let message = ChannelHealthController.silentRecordingMessage(for: .appOnly)

        XCTAssertFalse(message.contains("Both capture channels"), "only one channel was opened")
        XCTAssertFalse(message.lowercased().contains("input device"), "no microphone was opened")
        XCTAssertNotEqual(message, ChannelHealthController.silentRecordingMessage(for: .micAndApp))
        XCTAssertNotEqual(message, ChannelHealthController.silentRecordingMessage(for: .micOnly))
    }

    func testASilentMicrophoneOnlyRecordingIsToldWhatToCheck() {
        let message = ChannelHealthController.silentRecordingMessage(for: .micOnly)

        XCTAssertFalse(message.contains("Both capture channels"), "there is only one")
        XCTAssertFalse(message.contains("meeting app"), "a room recording has no meeting app")
        XCTAssertTrue(message.lowercased().contains("input device"))
        XCTAssertNotEqual(message, ChannelHealthController.silentRecordingMessage(for: .micAndApp))
    }
}
