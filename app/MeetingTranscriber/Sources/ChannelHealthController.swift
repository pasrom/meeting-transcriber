import AudioTapLib
import Foundation
import Observation
import os.log

/// Channel-health events go to the same subsystem `PersistentDiagnosticLog`
/// mirrors to `~/Library/Logs/MeetingTranscriber/`, so a recording that lost a
/// channel leaves a record the user can export afterwards. Until this existed
/// the controller logged nothing at all, and whether it had fired during a bad
/// recording was simply unknowable after the fact.
private let logger = Logger(subsystem: "com.meetingtranscriber", category: "ChannelHealth")

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

    /// The capture layer's rolling verdict: at least 90% exactly-zero samples
    /// across a full 120-second window, clearing at 50% or less. Already
    /// windowed, so no extra debounce or microphone corroboration applies.
    /// A listening user may never speak; this is evidence worth reporting,
    /// not proof of a wrong output device. Notifications share `appFault`'s
    /// per-recording silence policy rather than creating a parallel alert.
    private(set) var appDigitalSilenceActive: Bool = false

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

    /// Which channels the recording being watched actually opened. Set by
    /// `start(source:recorderProvider:)`; the levels alone cannot say, because
    /// an unopened channel and a dead one both read -120 dBFS.
    @ObservationIgnored private var channels: CapturedChannels = .micAndApp

    /// The window both fault monitors were built with, frozen for the
    /// recording. Read from settings once, at `rebuild()`, so the threshold a
    /// fault is judged against and the one its corroboration is judged against
    /// cannot come apart if the slider moves mid-recording.
    @ObservationIgnored private var faultWindow: TimeInterval

    /// The capture fault reported for each channel in this recording, if any.
    /// The notification is gone the moment it is posted; this is what a driver
    /// script polls and what a field diagnosis reads back.
    private(set) var micFault: ChannelFault?
    private(set) var appFault: ChannelFault?

    /// The ages the last tick saw, kept beside the verdict so the evidence for
    /// it is readable too: a channel called dead at ten seconds and one called
    /// dead at ten minutes are different bugs.
    ///
    /// Deliberately not observable, unlike the fault beside it. These change on
    /// every read by construction (an age is `now` minus a stamp), so a view
    /// bound to them would invalidate ten times a second forever, and the
    /// equality guard that looks like the fix would suppress nothing. The only
    /// reader is the RPC snapshot, which pulls on demand.
    @ObservationIgnored private(set) var micAges: ChannelSignalAges = .unknown
    @ObservationIgnored private(set) var appAges: ChannelSignalAges = .unknown

    /// The levels the last tick read. Not what decides a fault any more, but
    /// still what decides the menu-bar tint, and the only way to tell a channel
    /// sitting just under the silence threshold from one sitting just over it.
    /// Nothing exposed them before, so diagnosing why an episode did or did not
    /// latch meant inferring the level from the flag it produced.
    /// `@ObservationIgnored` for the same reason as the ages: written every
    /// tick, read only by the RPC snapshot.
    @ObservationIgnored private(set) var micLevelDBFS: Double?
    @ObservationIgnored private(set) var appLevelDBFS: Double?

    /// Per-channel "is this channel still delivering" decision, evaluated on
    /// every tick. Separate from `channelHealthMonitor`, which answers the
    /// louder-than-the-other question that drives the tint; see
    /// `ChannelFaultMonitor` for why one cannot serve for both.
    @ObservationIgnored private var micFaultMonitor: ChannelFaultMonitor
    @ObservationIgnored private var appFaultMonitor: ChannelFaultMonitor

    /// When this recording's first tick arrived, so a channel that has never
    /// delivered anything is judged against the age of the recording rather
    /// than against an absent timestamp.
    @ObservationIgnored private var firstTickAt: Date?

    /// When each channel last carried speech. A channel of digital silence is
    /// only reported while the *other* one proves the recording is capturing
    /// something; see `ChannelFaultMonitor.update(ages:elapsedSinceStart:corroborated:)`.
    @ObservationIgnored private var lastSpeechAt: [AudioChannel: Date] = [:]

    /// Red tint for the menu bar's **top** half. Composed here rather than at
    /// the call site so the topology that suppresses a phantom channel is
    /// applied in exactly one place, and so is the user's preference about the
    /// tint: the flags above stay the monitors' own truth, which is what
    /// `/state` reports and what the notifications are decided from, while this
    /// is the only place the icon setting can change anything.
    ///
    /// The observable flags are read into a local first, deliberately. Written
    /// as `channels.mic && (...)` the `&&` short-circuits, so on a recording
    /// without this channel the getters never run and `@Observable` registers no
    /// dependency on them for that render pass.
    var micSilentOverlay: Bool {
        let silent = micSilentActive || recordingSilentActive
        return indicatorEnabled() && channels.mic && silent
    }

    /// Red tint for the menu bar's **bottom** half. See `micSilentOverlay` for
    /// why the flags are read before the topology is consulted.
    var appSilentOverlay: Bool {
        let silent = appSilentActive || recordingSilentActive || appDigitalSilenceActive
        return indicatorEnabled() && channels.app && silent
    }

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
        self.faultWindow = debounceSeconds()
        self.micFaultMonitor = ChannelFaultMonitor(window: faultWindow)
        self.appFaultMonitor = ChannelFaultMonitor(window: faultWindow)
    }

    /// Starts a ~10 Hz polling task that feeds the active recorder's per-channel
    /// levels into the monitors and flips the observable flags based on the
    /// resulting events. Idempotent: calling while already running is a no-op.
    ///
    /// `recorderProvider` is supplied by the caller (it resolves the live
    /// `WatchLoop.activeRecorder`) so the controller stays free of an AppState
    /// back-reference. A tick where it returns nil is skipped, not fatal.
    func start(
        source: RecordingSource,
        recorderProvider: @escaping @MainActor () -> (any RecordingProvider)?,
    ) {
        // Before the guards: a start that turns back still records which
        // channels this recording has, so a stale topology from the previous
        // one cannot decide what the icon paints.
        channels = source.capturedChannels
        // NOT gated on `indicatorEnabled()`. That setting is named for the
        // menu-bar tint and its help text describes an indicator, but gating
        // the task here also silenced every capture-failure notification,
        // including the one failure that cannot recover on its own and whose
        // only remedy is restarting the app. Someone who finds a red icon
        // distracting was opting out of being told their microphone died. The
        // setting is applied where it belongs instead, in the two overlays.
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
        resetPerRecordingState()
        // Per-recording state like the flags above. Defensive rather than
        // load-bearing: every `start` sets the topology before its own guards,
        // so no reader can reach a stale value. Deliberately untested for that
        // reason — a test for it passes with the line deleted.
        channels = .micAndApp
    }

    /// Rebuilds both monitors with the current settings-driven debounce. Also
    /// exposed as a test seam so the "user changed threshold between recordings"
    /// path can be simulated without spinning up the polling Task.
    func simulateStartForTests(channels: CapturedChannels = .micAndApp) {
        self.channels = channels
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
        channelHealthMonitor = ChannelHealthMonitor(debounceSeconds: debounceSeconds(), channels: channels)
        silentRecordingMonitor = SilentRecordingMonitor(debounceSeconds: debounceSeconds())
        faultWindow = debounceSeconds()
        micFaultMonitor = ChannelFaultMonitor(window: faultWindow)
        appFaultMonitor = ChannelFaultMonitor(window: faultWindow)
        resetPerRecordingState()
    }

    /// Everything that is scoped to one recording. Written once and called from
    /// both ends of the lifecycle, because as two hand-kept lists the two had
    /// already drifted: only `stop()` cleared the give-up latch, so a `start()`
    /// not preceded by a `stop()` would have swallowed the next give-up report.
    private func resetPerRecordingState() {
        micFaultMonitor.reset()
        appFaultMonitor.reset()
        micFault = nil
        appFault = nil
        appDigitalSilenceActive = false
        micAges = .unknown
        appAges = .unknown
        micLevelDBFS = nil
        appLevelDBFS = nil
        firstTickAt = nil
        lastSpeechAt.removeAll()
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

        if firstTickAt == nil { firstTickAt = now }
        micAges = recorder.micSignalAges
        appAges = recorder.appSignalAges
        micLevelDBFS = mic
        appLevelDBFS = app
        // The monitor's own threshold, not a copy of its default: the init
        // allows a different one, and a second constant could then disagree
        // with the episode the tint is drawn from.
        let speechThreshold = channelHealthMonitor.speechThresholdDBFS
        if mic >= speechThreshold { lastSpeechAt[.mic] = now }
        if app >= speechThreshold { lastSpeechAt[.app] = now }
        let digitallySilent = channels.app && recorder.appCaptureDigitallySilent
        if appDigitalSilenceActive != digitallySilent {
            appDigitalSilenceActive = digitallySilent
            if !digitallySilent {
                logger.info("The app-audio rolling digital-silence verdict cleared")
            }
        }

        // Before the monitors, because a terminal capture failure does not
        // depend on either monitor having something to say about it.
        notifyChannelFaults(recorder: recorder, now: now)

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
            // No notification here any more. An episode says one channel is
            // quieter than the other, which is true of a muted microphone, of
            // a room where nobody is talking, and of a dead tap alike, and
            // reporting all three is what issue #614 is about. Whether this
            // channel is actually broken is decided per tick, from the buffer
            // ages, in `notifyChannelFaults`.

        case let .recovered(channel):
            micSilentActive = false
            appSilentActive = false
            logger.info(
                "The \(String(describing: channel), privacy: .public) channel is carrying audio again",
            )

        case .none:
            break
        }

        let silentEvent = silentRecordingMonitor.update(micDBFS: mic, appDBFS: app, now: now)
        applySilentRecording(silentEvent, mic: mic, app: app)

        return event
    }

    /// Handle the symmetric-silence monitor's verdict. Split from `applyTick`
    /// purely for length; it has no callers of its own.
    private func applySilentRecording(
        _ silentEvent: SilentRecordingEvent?, mic: Double, app: Double,
    ) {
        switch silentEvent {
        case .started:
            recordingSilentActive = true
            // The app fault already explains this silent recording. Keep the
            // level-driven tint, without a second notification about it.
            guard !appDigitalSilenceActive else { return }
            logger.error(
                "Every channel this recording opened has stayed at the noise floor (mic=\(mic, privacy: .public) dBFS, app=\(app, privacy: .public) dBFS)",
            )
            notifier.notify(
                title: "Recording Appears Silent",
                body: Self.silentRecordingMessage(for: channels),
                // Suppressible on purpose, see `captureAlert(channel:fault:)`: an auto-detected
                // recording starts when the detector confirms rather than when
                // anyone speaks, so a waiting room looks exactly like this.
                urgency: .standard,
            )

        case .recovered:
            recordingSilentActive = false
            logger.info("The recording is carrying audio again")

        case .none:
            break
        }
    }

    /// Reports what is wrong with each channel this recording opened, at most
    /// one silence report plus a terminal give-up per recording. Evidence comes
    /// from native signal ages, the rolling app verdict, and the give-up flags.
    ///
    /// One pass over both, rather than a give-up pass and a fault pass with a
    /// guard between them. Two passes meant the precedence lived in the call
    /// order and in a `contains` check rather than anywhere it could be read:
    /// a channel that gave up first never set a fault at all, so `/state`
    /// reported no fault for the most severe failure there is, and one that
    /// gave up second was announced twice.
    private func notifyChannelFaults(recorder: any RecordingProvider, now: Date) {
        let elapsed = now.timeIntervalSince(firstTickAt ?? now)
        for channel in [AudioChannel.mic, .app] {
            guard channel == .mic ? channels.mic : channels.app else { continue }
            let ages = channel == .mic ? micAges : appAges
            let gaveUp = channel == .mic ? recorder.micCaptureGaveUp : recorder.appCaptureGaveUp
            let rollingSilence = channel == .app && appDigitalSilenceActive
            guard let fault = updateFaultMonitor(
                for: channel, ages: ages, gaveUp: gaveUp, elapsedSinceStart: elapsed, now: now,
            ) ?? (rollingSilence ? .digitalSilence : nil) else { continue }
            // The rolling verdict bypasses the age monitor's debounce, but
            // not its reporting policy. Use the already-published fault as the
            // shared silence latch, so either evidence source may report first
            // without a duplicate when the other catches up. Give-up still
            // escalates, and the age monitor remains its once-only gate.
            let reportedFault = channel == .mic ? micFault : appFault
            guard reportedFault == nil || fault == .gaveUp else { continue }
            logger.error(
                "Capture fault on the \(String(describing: channel), privacy: .public) channel: \(fault.rawValue, privacy: .public) (rollingDigitalSilence=\(rollingSilence, privacy: .public))",
            )
            switch channel {
            case .mic: micFault = fault
            case .app: appFault = fault
            }
            // "Never carried a non-zero sample in this recording" is what
            // separates a denied tap from one that died; see `faultMessage`.
            let alert = Self.captureAlert(
                channel: channel, fault: fault,
                everCarriedSignal: ages.secondsSinceLastEnergy != nil,
                rollingDigitalSilence: rollingSilence,
            )
            notifier.notify(title: alert.title, body: alert.body, urgency: alert.urgency)
        }
    }

    private func updateFaultMonitor(
        for channel: AudioChannel,
        ages: ChannelSignalAges,
        gaveUp: Bool,
        elapsedSinceStart: TimeInterval,
        now: Date,
    ) -> ChannelFault? {
        let otherChannel: AudioChannel = channel == .mic ? .app : .mic
        // The window the monitors were built with, not the live setting: a
        // change mid-recording would otherwise judge the fault against one
        // threshold and its corroboration against another, and a corroboration
        // that was fresh a moment ago would expire retroactively.
        let corroborated = lastSpeechAt[otherChannel].map { speechAt in
            now.timeIntervalSince(speechAt) <= faultWindow
        } ?? false
        return switch channel {
        case .mic: micFaultMonitor.update(
                ages: ages, gaveUp: gaveUp, elapsedSinceStart: elapsedSinceStart,
                corroborated: corroborated,
            )

        case .app: appFaultMonitor.update(
                ages: ages, gaveUp: gaveUp, elapsedSinceStart: elapsedSinceStart,
                corroborated: corroborated,
            )
        }
    }
}
