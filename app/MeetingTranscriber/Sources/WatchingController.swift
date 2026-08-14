import Foundation
import Observation

// MARK: - WatchingController

/// Owns the watching / recording lifecycle: the active `WatchLoop`, the
/// auto-detect toggle, manual recording start/stop, the per-recording recorder
/// factory (which installs live-transcription sinks), and the state-change
/// handler that drives channel-health monitoring + error notifications.
///
/// Extracted from `AppState` as a concern-specific controller (see the AppState
/// god-class split). Unlike the earlier leaf controllers, watching is a hub: it
/// reaches across the already-extracted siblings — `pipeline` (to rebuild/ensure
/// the queue and pass it to the loop), `channelHealth` (start/stop on state
/// transitions), `permissions` (seed the loop's permission checker), and
/// `liveTranscription` (attach live sinks to each recorder). It holds those
/// siblings as direct references (not an `AppState` back-reference) since they
/// are all constructed before this controller in `AppState.init`.
///
/// Testability seams: `ensureMicAccess` + `makeDetector` are injectable (default
/// to the production `Permissions.ensureMicrophoneAccess` / `PowerAssertionDetector`)
/// so `toggleWatching` can be exercised without real TCC or IOKit. `syncEngines`
/// is wired post-init via `activate(syncEngines:)`: it bridges to
/// `EngineController.syncEngineSettings()` (held by `AppState`, not injected
/// here as a sibling) and the closure must capture `self` after stored-property
/// init — the same post-init wiring idiom the other controllers use.
@Observable
@MainActor
final class WatchingController {
    var watchLoop: WatchLoop?

    /// Non-nil while `toggleWatching`'s async start is in flight — it awaits mic
    /// access before `watchLoop` is assigned, so without this a second toggle in
    /// that window would launch a duplicate start. Cleared when the start task
    /// finishes.
    private var startTask: Task<Void, Never>?

    private let settings: AppSettings
    private let notifier: any AppNotifying
    private let pipeline: PipelineController
    private let channelHealth: ChannelHealthController
    private let permissions: PermissionsController
    private let liveTranscription: LiveTranscriptionCoordinator

    /// Microphone-access gate. Injectable so tests skip the real TCC prompt; the
    /// return value is intentionally ignored (the loop is created regardless, and
    /// surfaces a permission problem through its own `permissionChecker`).
    private let ensureMicAccess: () async -> Bool

    /// Screen-Recording request, fired at watch start. Injectable so tests skip
    /// the real TCC prompt.
    ///
    /// Asking is what registers the app in the Screen Recording list at all —
    /// preflighting never does — and until it is listed there is nothing for
    /// the user to switch on. It sits here, next to the microphone gate, rather
    /// than in the health check: that runs on every activation, so the request
    /// would keep arriving while the user is trying to work, and a checker
    /// causing a system prompt is a side effect nothing can inject around.
    ///
    /// The result is ignored, like the microphone gate: the permission only
    /// improves the detected meeting's title (`PowerAssertionDetector` falls
    /// back to a placeholder), so watching proceeds either way and the health
    /// check reports the state.
    private let requestScreenRecording: () -> Void

    /// Accessibility request, fired at watch start. Injectable so tests skip
    /// the real TCC prompt.
    ///
    /// `PermissionHealthCheck` already reports a missing Accessibility grant as
    /// a problem — red menu-bar badge plus a notification — because
    /// `ParticipantReader` needs it to read the Teams roster via
    /// `AXUIElementCreateApplication`. Without this call nothing ever showed the
    /// prompt, so the app diagnosed the problem but never offered the fix and
    /// the user had to find the Accessibility pane unaided.
    ///
    /// It belongs at watch start for the same reason the Screen-Recording
    /// request does: the health check runs on every activation, so prompting
    /// there would interrupt a user who is trying to work.
    ///
    /// Narrower than its two siblings on three axes, because full computer
    /// control is the most invasive grant on macOS and this one only enriches a
    /// recording. It fires only from a user-initiated toggle, since auto-watch
    /// otherwise raises a system alert three seconds after every launch with no
    /// click of any kind; only when `watchTeams` is on, since the roster read is
    /// the grant's sole consumer and is itself Teams-gated; and the production
    /// default is compiled out of the sandboxed build, which cannot use the API
    /// against another process at all.
    ///
    /// The result is ignored, like the other two gates. Watching, capture and
    /// transcription all work without the grant, so a refusal must not block the
    /// start.
    private let requestAccessibility: () -> Void

    /// Meeting detector factory for the auto-detect path. Injectable so tests can
    /// supply a deterministic detector instead of the IOKit-backed
    /// `PowerAssertionDetector`.
    private let makeDetector: () -> any MeetingDetecting

    /// Engine-sync hook, wired by `activate`. Bridges to
    /// `EngineController.syncEngineSettings()`; nil until `activate` runs, in
    /// which case the up-front sync is skipped (EngineController's own reactive
    /// observer still keeps the engines in line).
    private var syncEngines: (() -> Void)?

    init(
        settings: AppSettings,
        notifier: any AppNotifying,
        pipeline: PipelineController,
        channelHealth: ChannelHealthController,
        permissions: PermissionsController,
        liveTranscription: LiveTranscriptionCoordinator,
        ensureMicAccess: @escaping () async -> Bool = { await Permissions.ensureMicrophoneAccess() },
        requestScreenRecording: @escaping () -> Void = { Permissions.ensureScreenRecordingAccess() },
        requestAccessibility: @escaping () -> Void = {
            #if !APPSTORE
                Permissions.ensureAccessibilityAccess()
            #endif
        },
        makeDetector: (() -> any MeetingDetecting)? = nil,
    ) {
        self.settings = settings
        self.notifier = notifier
        self.pipeline = pipeline
        self.channelHealth = channelHealth
        self.permissions = permissions
        self.liveTranscription = liveTranscription
        self.ensureMicAccess = ensureMicAccess
        self.requestScreenRecording = requestScreenRecording
        self.requestAccessibility = requestAccessibility
        // Tests inject a deterministic detector; production defaults to one
        // filtered by the "Apps to Watch" toggles, re-read at each watch start.
        self.makeDetector = makeDetector ?? { [settings] in
            Self.defaultDetector(settings: settings)
        }
    }

    /// The auto-detect detector, filtered by the user's "Apps to Watch" toggles
    /// (`settings.watchApps`). Extracted so the toggle → detection wiring is
    /// unit-testable without spinning up a watch loop.
    static func defaultDetector(settings: AppSettings) -> any MeetingDetecting {
        CompositeMeetingDetector(defaultDetectors(settings: settings))
    }

    /// The strategies `defaultDetector` composes, in priority order. Split out
    /// so the toggle wiring stays assertable: a test can configure one
    /// strategy's injectable providers without reaching into the composite.
    static func defaultDetectors(settings: AppSettings) -> [any MeetingDetecting] {
        let assertions = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: settings.watchApps),
        )
        // Read through the settings each poll rather than captured once, so a
        // Settings "Remove" takes effect without restarting the watch loop.
        assertions.isIdentityDenied = { [settings] app in
            settings.consentDeniedApps.contains(app)
        }
        return [
            assertions,
            MicInputDetector(patterns: MicInputDetector.patterns(watching: settings.watchApps)),
        ]
    }

    /// Wire the engine-sync hook. Called once from `AppState.init` after its
    /// stored-property init, where the `[weak self]` AppState closure is valid.
    func activate(syncEngines: @escaping () -> Void) {
        self.syncEngines = syncEngines
    }

    // MARK: - Derived

    var isWatching: Bool {
        watchLoop?.isActive == true && watchLoop?.isManualRecording == false
    }

    /// Whether a recording is currently in progress (the watch loop is in its
    /// `.recording` state).
    var isRecording: Bool {
        watchLoop?.state == .recording
    }

    // MARK: - Start / Stop

    /// - Parameter userInitiated: True for a deliberate Start/Stop press, which
    ///   is the one moment where asking for an optional permission is warranted.
    ///   The auto-watch path passes false so an unattended launch raises no
    ///   system alert — including on the e2e runners, which force auto-watch on
    ///   and where a stray dialog can swallow the keystroke a lane sends.
    func toggleWatching(userInitiated: Bool = true) {
        if let loop = watchLoop, loop.isManualRecording { return }
        if let loop = watchLoop, loop.isActive {
            loop.stop()
            watchLoop = nil
        } else {
            // The start is async — mic access is awaited before `watchLoop` is
            // assigned — so a second toggle in that window would otherwise launch
            // a duplicate WatchLoop and rebuild the queue twice. Ignore it while
            // a start is already in flight.
            guard startTask == nil else { return }
            startTask = Task { @MainActor in
                defer { startTask = nil }
                await requestStartPermissions(userInitiated: userInitiated)

                syncEngines?()
                pipeline.rebuild()

                let detector = makeDetector()

                let loop = WatchLoop(
                    detector: detector,
                    recorderFactory: makeRecorderFactory(),
                    pipelineQueue: pipeline.queue,
                    pollInterval: settings.pollInterval,
                    endGracePeriod: settings.endGrace,
                    noMic: settings.noMic,
                    micDeviceUID: settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID,
                    verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
                    recordOnly: { [settings] in settings.recordOnly },
                    recordOnlyDestination: { [settings] in
                        .production(parent: settings.effectiveOutputDir)
                    },
                    notifier: notifier,
                    denyListStore: ConsentDenyListStore(settings: settings),
                )

                attachStateChangeHandler(to: loop, notifyOnRecording: true)

                if let health = permissions.health {
                    loop.permissionChecker = { health }
                }

                watchLoop = loop
                loop.start()
            }
        }
    }

    /// The permissions a watch start asks for, in the order the user meets
    /// them. Only the mic gate is awaited, because capture cannot begin without
    /// it; the other two register the app in their System Settings pane and are
    /// reported by `PermissionHealthCheck` afterwards, so a refusal delays
    /// nothing here.
    ///
    /// - Parameter userInitiated: see `toggleWatching`.
    private func requestStartPermissions(userInitiated: Bool) async {
        _ = await ensureMicAccess()
        requestScreenRecording()
        if userInitiated, settings.watchTeams {
            requestAccessibility()
        }
    }

    func startManualRecording(pid: pid_t, appName: String, title: String) {
        // Stop auto-watch if active
        if let loop = watchLoop, loop.isActive, !loop.isManualRecording {
            loop.stop()
            watchLoop = nil
        }

        Task { @MainActor in
            _ = await ensureMicAccess()

            pipeline.ensureQueue()

            // Manual recording never polls the detector, so WatchLoop's default
            // (unfiltered) detector here is inert, and so is the consent gate
            // that hangs off it: no detection means no prompt, hence no deny
            // list to consult, hence the default in-memory store. If this path
            // ever gains auto-detection, route it through `makeDetector()` like
            // toggleWatching so the "Apps to Watch" filter still applies, and
            // pass `denyListStore:` so a "Never for this app" is honoured here
            // too.
            let loop = WatchLoop(
                recorderFactory: makeRecorderFactory(),
                pipelineQueue: pipeline.queue,
                pollInterval: settings.pollInterval,
                noMic: settings.noMic,
                micDeviceUID: settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID,
                verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
                recordOnly: { [settings] in settings.recordOnly },
                recordOnlyDestination: { [settings] in
                    .production(parent: settings.effectiveOutputDir)
                },
                notifier: notifier,
            )
            watchLoop = loop

            // Wire channel-health monitoring + error notification on state
            // transitions — same hook the auto-detect path installs, so the
            // red-tint indicator and asymmetric-silence notification work
            // for manual recordings too.
            attachStateChangeHandler(to: loop, notifyOnRecording: false)

            // Use cached health check result instead of live probe
            if let health = permissions.health {
                loop.permissionChecker = { health }
            }

            do {
                try await loop.startManualRecording(pid: pid, appName: appName, title: title)
                notifier.notify(
                    title: "Manual Recording",
                    body: "Recording: \(title)",
                )
            } catch {
                notifier.notify(title: "Error", body: error.localizedDescription)
                watchLoop = nil
            }
        }
    }

    func stopManualRecording() {
        watchLoop?.stopManualRecording()
        watchLoop = nil
    }

    // MARK: - Recorder factory

    /// Build the `recorderFactory` closure for `WatchLoop`. Returns a fresh
    /// `DualSourceRecorder` on each invocation; when live captions are eligible,
    /// the coordinator installs mic + app live sinks that pipe captured buffers to
    /// the `LiveTranscriptionController`. `async` so the coordinator can await the
    /// prior recording's stop-time flush before reusing a kept EOU session.
    private func makeRecorderFactory() -> @MainActor () async -> any RecordingProvider {
        { [weak self] in
            let recorder = DualSourceRecorder()
            await self?.liveTranscription.attachSinks(to: recorder)
            return recorder
        }
    }

    // MARK: - State-change handler

    /// Attaches the state-change callback that drives channel-health monitoring
    /// and post-`.error` notifications. Shared between the auto-detect path
    /// (`toggleWatching`) and the manual-recording path (`startManualRecording`)
    /// so the red-tint indicator + asymmetric-silence notification fire in both.
    /// `notifyOnRecording` only fires "Meeting Detected" notifications for the
    /// auto-detect path; manual recording emits its own start notification.
    private func attachStateChangeHandler(to loop: WatchLoop, notifyOnRecording: Bool) {
        loop.onStateChange = { [weak self, weak loop, notifier] oldState, newState in
            // Leaving `.recording` (natural meeting end, manual stop, or
            // mid-recording cancel — all route through this transition) is the
            // unified stop signal for both the auto-detect and manual paths.
            // Flush the live pipeline here so the pending tail utterance is
            // committed before the next recording's prepareForNextRecording() clears state. The
            // flush runs after `recorder.stop()` (WatchLoop stops the recorder
            // before this transition fires); the buffered tail lives in the
            // streaming actors, not the recorder, so it survives the stop.
            if oldState == .recording {
                Task { @MainActor in await self?.liveTranscription.flush() }
            }
            switch newState {
            case .recording:
                if notifyOnRecording, let meeting = loop?.currentMeeting {
                    notifier.notify(
                        title: "Meeting Detected",
                        body: "Recording: \(meeting.windowTitle)",
                    )
                }
                self?.channelHealth.start { [weak self] in self?.watchLoop?.activeRecorder }

            case .error:
                if let err = loop?.lastError {
                    notifier.notify(title: "Error", body: err)
                }
                self?.channelHealth.stop()

            default:
                self?.channelHealth.stop()
            }
        }
    }
}
