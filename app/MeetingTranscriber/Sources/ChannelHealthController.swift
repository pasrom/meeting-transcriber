import Foundation
import Observation

// MARK: - ChannelHealthController

/// Owns the per-channel + symmetric-silence detection that drives the menu-bar
/// red-tint indicators while recording.
///
/// Extracted from `AppState` as a concern-specific controller (see the AppState
/// god-class split). `AppState` holds it as a sub-controller, wires `start()` /
/// `stop()` to `WatchLoop` state transitions, and exposes the observable flags
/// to the menu-bar icon + RPC snapshot.
///
/// Two sibling state machines run off one 10 Hz poll:
/// - `ChannelHealthMonitor` — asymmetric silence (one channel dead while the
///   other carries speech), drives `micSilentActive` / `appSilentActive`.
/// - `SilentRecordingMonitor` — symmetric silence (both channels dead), the case
///   the asymmetric monitor intentionally ignores, drives `recordingSilentActive`.
///
/// The `debounceSeconds` / `indicatorEnabled` closures read live from settings;
/// `recorderProvider` is passed to `start()` (not stored at init) so the
/// controller never holds an `AppState` back-reference. This keeps the polling
/// + notification logic testable against a mock recorder without a `WatchLoop`.
@Observable
@MainActor
final class ChannelHealthController {
    /// True while the **mic** channel is silent and the app channel is carrying
    /// speech continuously for the debounce window. Drives the menu-bar
    /// **top-half** red tint. Latches until the dead channel recovers (or
    /// recording stops). At most one of `micSilentActive` / `appSilentActive`
    /// is true at a time — the monitor's channel-switch path resets when roles flip.
    private(set) var micSilentActive: Bool = false

    /// True while the **app-audio** channel is silent and the mic is carrying
    /// speech continuously for the debounce window. Drives the menu-bar
    /// **bottom-half** red tint.
    private(set) var appSilentActive: Bool = false

    /// True while **both** capture channels have been below the silence
    /// threshold continuously for the debounce window — the failure mode
    /// `ChannelHealthMonitor` intentionally ignores (symmetric silence). Drives
    /// the menu-bar **full red** waveform (both halves tinted simultaneously).
    private(set) var recordingSilentActive: Bool = false

    /// Pure state machine driven by the 10-Hz level poll while recording. Lives
    /// here (not on WatchLoop) so its lifecycle outlasts a single recording —
    /// observers of `micSilentActive` / `appSilentActive` keep their identity across the
    /// detect → record → process state churn.
    @ObservationIgnored private var channelHealthMonitor: ChannelHealthMonitor

    /// Sibling monitor that catches the symmetric-silence case
    /// `ChannelHealthMonitor` intentionally skips. Shares the same
    /// debounce threshold; lifecycle managed alongside the channel-health
    /// monitor in `start` / `stop`.
    @ObservationIgnored private var silentRecordingMonitor: SilentRecordingMonitor

    @ObservationIgnored private var levelMonitorTask: Task<Void, Never>?

    private let notifier: any AppNotifying
    private let debounceSeconds: () -> TimeInterval
    private let indicatorEnabled: () -> Bool

    init(
        notifier: any AppNotifying,
        debounceSeconds: @escaping () -> TimeInterval,
        indicatorEnabled: @escaping () -> Bool,
    ) {
        self.notifier = notifier
        self.debounceSeconds = debounceSeconds
        self.indicatorEnabled = indicatorEnabled
        self.channelHealthMonitor = ChannelHealthMonitor(debounceSeconds: debounceSeconds())
        self.silentRecordingMonitor = SilentRecordingMonitor(debounceSeconds: debounceSeconds())
    }

    /// Starts a ~10 Hz polling task that feeds the active recorder's per-channel
    /// levels into the monitors and flips the observable flags based on the
    /// resulting events. Idempotent: calling while already running is a no-op.
    /// Skips entirely when the master toggle is off.
    ///
    /// `recorderProvider` is supplied by the caller (it resolves the live
    /// `WatchLoop.activeRecorder`) so the controller stays free of an AppState
    /// back-reference. A tick where it returns nil is skipped, not fatal.
    func start(recorderProvider: @escaping @MainActor () -> (any RecordingProvider)?) {
        guard indicatorEnabled() else { return }
        guard levelMonitorTask == nil else { return }
        rebuild()
        levelMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let recorder = recorderProvider() {
                    self.applyTick(recorder: recorder, now: Date())
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Stops the polling task and resets the monitors + UI flags. Called when
    /// recording ends or an error transition happens.
    func stop() {
        levelMonitorTask?.cancel()
        levelMonitorTask = nil
        channelHealthMonitor.reset()
        silentRecordingMonitor.reset()
        micSilentActive = false
        appSilentActive = false
        recordingSilentActive = false
    }

    /// Rebuilds both monitors with the current settings-driven debounce. Also
    /// exposed as a test seam so the "user changed threshold between recordings"
    /// path can be simulated without spinning up the polling Task.
    func simulateStartForTests() {
        rebuild()
    }

    #if !APPSTORE
        /// E2E hook: force the red-tint flags at launch so a driver script can
        /// assert the menu-bar pipeline end-to-end without orchestrating real
        /// audio. Keeps the flags `private(set)` for normal operation — only
        /// `AppState.init`'s env-var path calls this. See that call site for the
        /// `MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH` interaction.
        func applyForcedFlagsForE2E(micSilent: Bool, appSilent: Bool, recordingSilent: Bool) {
            micSilentActive = micSilent
            appSilentActive = appSilent
            recordingSilentActive = recordingSilent
        }
    #endif

    private func rebuild() {
        channelHealthMonitor = ChannelHealthMonitor(debounceSeconds: debounceSeconds())
        silentRecordingMonitor = SilentRecordingMonitor(debounceSeconds: debounceSeconds())
    }

    /// Internal test seam: drives one polling tick against an arbitrary
    /// recorder + clock. Production code's polling task calls this with the
    /// active recorder + wall clock.
    @discardableResult
    func applyTick(
        recorder: any RecordingProvider,
        now: Date,
    ) -> ChannelHealthEvent? {
        let mic = recorder.micLevelDBFS
        let app = recorder.appLevelDBFS

        let event = channelHealthMonitor.update(micDBFS: mic, appDBFS: app, now: now)
        switch event {
        case let .started(channel, _):
            switch channel {
            case .mic:
                micSilentActive = true
                appSilentActive = false

            case .app:
                appSilentActive = true
                micSilentActive = false
            }
            notifier.notify(
                title: "Capture Channel Silent",
                body: Self.asymmetricSilenceMessage(for: channel),
            )

        case .recovered:
            micSilentActive = false
            appSilentActive = false

        case .none:
            break
        }

        let silentEvent = silentRecordingMonitor.update(micDBFS: mic, appDBFS: app, now: now)
        switch silentEvent {
        case .started:
            recordingSilentActive = true
            notifier.notify(
                title: "Recording Appears Silent",
                body: Self.silentRecordingMessage,
            )

        case .recovered:
            recordingSilentActive = false

        case .none:
            break
        }

        return event
    }

    nonisolated static func asymmetricSilenceMessage(for channel: AudioChannel) -> String {
        switch channel {
        case .app:
            "The app-audio channel went silent while the mic is still carrying audio. "
                + "Check the meeting app's audio settings or system audio permission."

        case .mic:
            "The microphone went silent while the app audio is still recording. "
                + "Check the mic device, mute state, or microphone permission."
        }
    }

    nonisolated static let silentRecordingMessage: String =
        "Both capture channels have been silent since the recording started. "
            + "Check the audio routing — the meeting app may have claimed the mic "
            + "in exclusive mode (e.g. AirPods HFP), or the system input device may be muted."
}
