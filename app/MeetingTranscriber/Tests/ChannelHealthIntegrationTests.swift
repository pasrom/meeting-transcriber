@testable import MeetingTranscriber
import XCTest

/// Integration test of the AppState polling-tick path: drives `applyChannelHealthTick`
/// against a mock recorder with controllable per-channel levels and verifies the
/// observable flags + notification side-effects line up with the
/// `ChannelHealthMonitor` events.
///
/// Covers the production scenario "user mutes their mic while the meeting app's
/// audio continues to play other participants" — the mic input goes to -120 dBFS,
/// the app-audio CATapDescription channel keeps reporting speech levels, and the
/// indicator must fire `.started(.mic)` after the configured debounce.
@MainActor
final class ChannelHealthIntegrationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeState() -> (AppState, MockRecorder, RecordingNotifier, AppSettings) {
        let suite = "ChannelHealthIntegrationTests-\(getpid())-\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true
        // 30 s = the minimum the production clamp allows; tests time relative to this.
        settings.asymmetricSilenceWarningSeconds = 30

        let notifier = RecordingNotifier()
        let state = AppState(settings: settings, notifier: notifier)
        let recorder = MockRecorder()
        // AppState reads recorder via watchLoop?.activeRecorder. Skipping the
        // WatchLoop construction in the test — the `applyChannelHealthTick`
        // overload takes the recorder directly.
        return (state, recorder, notifier, settings)
    }

    // MARK: - Production scenario: user mutes their mic mid-meeting

    func testMutedMicWithAppSpeechFiresMicSilent() {
        let (state, recorder, notifier, _) = makeState()
        // Initialize monitor with the same debounce as production startChannelHealthMonitoring.
        // (The test bypasses the polling task; we still need a fresh monitor.)
        state.applyChannelHealthTick(recorder: recorder, now: t0) // warmup tick

        recorder.micLevelDBFS = -80 // muted
        recorder.appLevelDBFS = -25 // other participants speaking

        // Before debounce elapses: nothing fires
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0)
        XCTAssertFalse(state.micSilentActive)
        XCTAssertFalse(state.appSilentActive)
        XCTAssertEqual(notifier.calls.count, 0)

        // At debounce boundary: mic-silent fires
        let event = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertEqual(event, .started(channel: .mic, quietSince: t0))
        XCTAssertTrue(state.micSilentActive)
        XCTAssertFalse(state.appSilentActive)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "Capture Channel Silent")
        XCTAssertTrue(notifier.calls[0].body.lowercased().contains("microphone"))
    }

    func testMutedAppAudioWithMicSpeechFiresAppSilent() {
        let (state, recorder, notifier, _) = makeState()
        recorder.micLevelDBFS = -25 // user speaking
        recorder.appLevelDBFS = -80 // app audio dead (e.g. dropped CATapDescription)

        _ = state.applyChannelHealthTick(recorder: recorder, now: t0)
        let event = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertEqual(event, .started(channel: .app, quietSince: t0))
        XCTAssertTrue(state.appSilentActive)
        XCTAssertFalse(state.micSilentActive)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(notifier.calls[0].body.lowercased().contains("app-audio"))
    }

    // MARK: - Latch + recovery

    func testStartedFiresExactlyOncePerEpisode() {
        let (state, recorder, notifier, _) = makeState()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25

        _ = state.applyChannelHealthTick(recorder: recorder, now: t0)
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(30)) // .started
        XCTAssertEqual(notifier.calls.count, 1)

        // Subsequent ticks while the episode is latched must not re-fire.
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(40))
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(120))
        XCTAssertEqual(notifier.calls.count, 1, "notifier must fire exactly once per episode")
        XCTAssertTrue(state.micSilentActive)
    }

    func testRecoveryClearsBothFlags() {
        let (state, recorder, notifier, _) = makeState()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25

        _ = state.applyChannelHealthTick(recorder: recorder, now: t0)
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(30)) // .started
        XCTAssertTrue(state.micSilentActive)

        // Mic comes back online (user unmutes).
        recorder.micLevelDBFS = -25
        let event = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(40))
        XCTAssertEqual(event, .recovered(channel: .mic))
        XCTAssertFalse(state.micSilentActive)
        XCTAssertFalse(state.appSilentActive)
        // Recovery doesn't fire a notification today — only .started does.
        XCTAssertEqual(notifier.calls.count, 1)
    }

    // MARK: - Channel switch mid-episode

    func testChannelSwitchClearsOldFlagBeforeNewFires() {
        let (state, recorder, notifier, _) = makeState()
        // Phase 1: mic silent, app speaking — start tracking mic
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0)
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(30)) // mic .started
        XCTAssertTrue(state.micSilentActive)
        XCTAssertFalse(state.appSilentActive)

        // Phase 2: roles flip — mic recovers AND app dies. Monitor's channel-switch path resets.
        recorder.micLevelDBFS = -25
        recorder.appLevelDBFS = -80
        // Right at the swap: not asymmetric in the same direction → monitor returns to clean state.
        // Both flags clear via `.recovered`.
        let recovery = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(35))
        XCTAssertEqual(recovery, .recovered(channel: .mic))
        XCTAssertFalse(state.micSilentActive)
        XCTAssertFalse(state.appSilentActive)

        // Phase 3: app stays dead, mic stays alive — new episode tracks app
        let event = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(65))
        XCTAssertEqual(event, .started(channel: .app, quietSince: t0.addingTimeInterval(35)))
        XCTAssertFalse(state.micSilentActive)
        XCTAssertTrue(state.appSilentActive)
        XCTAssertEqual(notifier.calls.count, 2)
        XCTAssertTrue(notifier.calls[1].body.lowercased().contains("app-audio"))
    }

    // MARK: - Symmetric cases never fire

    func testBothChannelsActiveDoesNotFire() {
        let (state, recorder, notifier, _) = makeState()
        recorder.micLevelDBFS = -25
        recorder.appLevelDBFS = -25
        for offset in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }
        XCTAssertFalse(state.micSilentActive)
        XCTAssertFalse(state.appSilentActive)
        XCTAssertEqual(notifier.calls.count, 0)
    }

    func testBothChannelsSilentDoesNotFireAsymmetricFlags() {
        // Asymmetric monitor must NOT treat symmetric silence as an event
        // (its job is one-side-dead detection). The sibling
        // `SilentRecordingMonitor` *does* fire on this case — see
        // `testBothChannelsSilentFiresRecordingSilentAfterDebounce`.
        let (state, recorder, _, _) = makeState()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -80
        for offset in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }
        XCTAssertFalse(state.micSilentActive)
        XCTAssertFalse(state.appSilentActive)
    }

    // MARK: - Silent-recording (symmetric silence) detection

    func testBothChannelsSilentFiresRecordingSilentAfterDebounce() {
        // Sibling-monitor coverage of the 40-minute zero-audio failure
        // mode that shipped past PR #286: both channels at the noise
        // floor for the entire recording, no in-app warning. The new
        // `SilentRecordingMonitor` shares the same debounce as
        // `ChannelHealthMonitor` and fires `recordingSilentActive` plus
        // a notification.
        let (state, recorder, notifier, _) = makeState()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -80
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0)
        XCTAssertFalse(state.recordingSilentActive)
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertTrue(state.recordingSilentActive)
        // Asymmetric flags stay clear — semantics distinct from the
        // mic/app-silent path.
        XCTAssertFalse(state.micSilentActive)
        XCTAssertFalse(state.appSilentActive)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "Recording Appears Silent")
    }

    func testRecordingSilentRecoversWhenAnyChannelReturnsToSpeech() {
        let (state, recorder, _, _) = makeState()
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -80
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0)
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertTrue(state.recordingSilentActive)

        recorder.micLevelDBFS = -25
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(35))
        XCTAssertFalse(state.recordingSilentActive)
    }

    // MARK: - Settings re-init across recordings

    func testThresholdChangeBetweenRecordingsTakesEffectOnNextStart() {
        let (state, recorder, _, settings) = makeState()
        // First recording uses the initial 30 s debounce; warm-up tick.
        recorder.micLevelDBFS = -80
        recorder.appLevelDBFS = -25
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0)
        XCTAssertNil(
            state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(20)),
            "20s under initial 30s debounce should not fire yet",
        )

        // User stops watching → would normally call stopChannelHealthMonitoring,
        // then bumps the threshold up to 60s before starting again.
        settings.asymmetricSilenceWarningSeconds = 60
        state.simulateStartChannelHealthMonitoringForTests()

        // Replay the same asymmetric levels — but now 30s should NOT be enough.
        _ = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(100))
        XCTAssertNil(
            state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(140)),
            "40s under new 60s debounce should not fire — proves the monitor picked up the new threshold",
        )
        let event = state.applyChannelHealthTick(recorder: recorder, now: t0.addingTimeInterval(160))
        XCTAssertEqual(
            event,
            .started(channel: .mic, quietSince: t0.addingTimeInterval(100)),
            "60s under new threshold should fire — confirms threshold = 60",
        )
    }
}
