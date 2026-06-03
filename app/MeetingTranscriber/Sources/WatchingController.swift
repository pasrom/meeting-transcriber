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
/// `EngineController.syncLanguageSettings()` (held by `AppState`, not injected
/// here as a sibling) and the closure must capture `self` after stored-property
/// init — the same post-init wiring idiom the other controllers use.
@Observable
@MainActor
final class WatchingController {
    var watchLoop: WatchLoop?

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
    /// `EngineController.syncLanguageSettings()`; nil until `activate` runs, in
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
        makeDetector: @escaping () -> any MeetingDetecting = { PowerAssertionDetector() },
    ) {
        self.settings = settings
        self.notifier = notifier
        self.pipeline = pipeline
        self.channelHealth = channelHealth
        self.permissions = permissions
        self.liveTranscription = liveTranscription
        self.ensureMicAccess = ensureMicAccess
        self.makeDetector = makeDetector
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

    // MARK: - Start / Stop

    func toggleWatching() {
        if let loop = watchLoop, loop.isManualRecording { return }
        if let loop = watchLoop, loop.isActive {
            loop.stop()
            watchLoop = nil
        } else {
            Task { @MainActor in
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
    /// `DualSourceRecorder` on each invocation; when live transcription is on AND
    /// the active engine supports `transcribeSamples`, the coordinator installs
    /// mic + app live sinks that pipe captured buffers to the
    /// `LiveTranscriptionController`.
    private func makeRecorderFactory() -> @MainActor () -> any RecordingProvider {
        { [weak self] in
            let recorder = DualSourceRecorder()
            self?.liveTranscription.attachSinks(to: recorder)
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
        loop.onStateChange = { [weak self, weak loop, notifier] _, newState in
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
