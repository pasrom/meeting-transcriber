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
        makeDetector: (() -> any MeetingDetecting)? = nil,
    ) {
        self.settings = settings
        self.notifier = notifier
        self.pipeline = pipeline
        self.channelHealth = channelHealth
        self.permissions = permissions
        self.liveTranscription = liveTranscription
        self.ensureMicAccess = ensureMicAccess
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
        PowerAssertionDetector(patterns: PowerAssertionDetector.patterns(watching: settings.watchApps))
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

    func toggleWatching() {
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
                _ = await ensureMicAccess()

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
            // (unfiltered) detector here is inert. If this path ever gains
            // auto-detection, route it through `makeDetector()` like toggleWatching
            // so the "Apps to Watch" filter still applies.
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
