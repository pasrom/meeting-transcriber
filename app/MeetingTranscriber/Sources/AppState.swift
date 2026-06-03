// swiftlint:disable file_length
import AppKit
import Foundation
import Observation
import os.log

// MARK: - AppNotifying

/// Notification abstraction that keeps AppKit out of AppState.
///
/// Real implementation: `NotificationManager` (AppKit, used in menu bar app).
/// Test implementation: `RecordingNotifier` (records calls, no side effects).
protocol AppNotifying {
    func notify(title: String, body: String)
}

// MARK: - AppState

/// Observable ViewModel that composes the app's concern-specific controllers
/// (`pipeline`, `permissions`, `channelHealth`, `liveTranscription`,
/// `rpcController`) and exposes the derived UI properties (badge, status label)
/// the menu-bar scene binds to. It wires the controllers together rather than
/// owning their state — new concern state belongs in a controller, not here.
///
/// Extracted from `MeetingTranscriberApp` so badge/watching logic and
/// `BadgeKind.compute(...)` are testable without the `@main` App struct.
@Observable
@MainActor
final class AppState {
    // MARK: - Dependencies

    let settings: AppSettings
    let whisperKit: WhisperKitEngine
    let parakeetEngine: ParakeetEngine
    // Only created on macOS 15+ where Qwen3-ASR is available.
    private let _qwen3Engine: AnyObject?
    private let notifier: any AppNotifying

    /// Typed accessor (only callable under @available(macOS 15, *) checks).
    @available(macOS 15, *)
    var qwen3Engine: Qwen3AsrEngine {
        // swiftlint:disable:next force_cast
        _qwen3Engine as! Qwen3AsrEngine
    }

    // MARK: - State

    var watchLoop: WatchLoop?
    var updateChecker: UpdateChecker
    var selectedNamingJobID: UUID?

    /// Post-processing pipeline concern (the `PipelineQueue` instance, its
    /// wiring from settings + active engine, job-state notifications, and the
    /// file-enqueue entry points), extracted into its own controller. Read as
    /// `pipeline.queue` by the menu-bar UI + RPC snapshot. `AppState` supplies
    /// the active engine via `activate(engineProvider:)` post-init.
    let pipeline: PipelineController

    /// Live TCC permission-health concern, extracted into its own controller.
    /// `currentBadge` composes its `health` into the `.error` state.
    let permissions: PermissionsController

    /// Per-channel + symmetric-silence detection that drives the menu-bar
    /// red-tint indicators while recording. Extracted into its own controller;
    /// `attachStateChangeHandler` wires its `start()` / `stop()` to `WatchLoop`
    /// state transitions, and the menu-bar icon + RPC snapshot read its flags.
    let channelHealth: ChannelHealthController

    /// Observable state for the live caption overlay. Always present (the
    /// `LiveCaptionsOverlay` window observes this); content is only populated
    /// when live transcription is on AND a recording is active. Owned here (read
    /// by the overlay window + RPC snapshot) and injected into `liveTranscription`.
    let liveCaptions: LiveCaptionsState = .init()

    /// Live-transcription controller lifecycle (lazy creation against the active
    /// engine, pre-warm, per-recording sink installation), extracted into its own
    /// coordinator. `makeRecorderFactory` delegates sink installation to it.
    let liveTranscription: LiveTranscriptionCoordinator

    #if !APPSTORE
        /// Debug RPC server lifecycle (launch gate, settings-driven start/stop,
        /// token rotation), extracted into its own controller. `AppState` supplies
        /// the wired server via `buildDebugRPCServer()` and keeps the state
        /// projection (`rpcStateSnapshot`) + speaker-DB actions.
        let rpcController: RPCServerController

        /// Background `log stream` subprocess that mirrors our subsystems to
        /// `~/Library/Logs/MeetingTranscriber/diagnostics-YYYY-MM-DD.log`.
        /// Survives longer than OSLogStore retention (~1h for `.info`).
        private(set) var persistentLogStreamer: PersistentDiagnosticLog.Streamer?
    #endif

    // MARK: - Dependency factories

    // These exist purely to keep the dependency-default construction out of
    // `init`'s type-check budget — see the comment at the top of `init`.
    // Each has an explicit return type so the call site resolves to a plain
    // function reference instead of re-solving the dependency's init.

    private static func makeDefaultSettings() -> AppSettings {
        AppSettings()
    }

    private static func makeWhisperKit() -> WhisperKitEngine {
        WhisperKitEngine()
    }

    private static func makeParakeet() -> ParakeetEngine {
        ParakeetEngine()
    }

    private static func makeUpdateChecker() -> UpdateChecker {
        UpdateChecker()
    }

    @available(macOS 15, *)
    private static func makeQwen3() -> Qwen3AsrEngine {
        Qwen3AsrEngine()
    }

    // MARK: - Init

    init(
        settings: AppSettings = AppState.makeDefaultSettings(),
        whisperKit: WhisperKitEngine? = nil,
        parakeetEngine: ParakeetEngine? = nil,
        qwen3Engine: AnyObject? = nil,
        notifier: any AppNotifying = SilentNotifier(),
        updateChecker: UpdateChecker? = nil,
    ) {
        // Dependency defaults are resolved through explicitly-typed factory
        // helpers (above) rather than inline `?? SomeType()` expressions (and
        // an inline `AppSettings()` default argument). Each inline
        // `@Observable` / protocol-existential constructor forces the
        // type-checker to re-solve the dependency's own init constraints at
        // this call site; summed across the engine + settings dependencies
        // that pushed this init's body-type-check time right up against the
        // 300 ms hard limit enforced in Package.swift, where it flaked
        // intermittently under heavy CI load. A factory with a declared
        // return type collapses the inference here to a plain function
        // reference. Behaviour is identical.
        self.settings = settings
        self.whisperKit = whisperKit ?? Self.makeWhisperKit()
        self.parakeetEngine = parakeetEngine ?? Self.makeParakeet()
        if #available(macOS 15, *) {
            self._qwen3Engine = (qwen3Engine as? Qwen3AsrEngine) ?? Self.makeQwen3()
        } else {
            self._qwen3Engine = nil
        }
        self.notifier = notifier
        self.permissions = PermissionsController(notifier: notifier)
        self.updateChecker = updateChecker ?? Self.makeUpdateChecker()
        self.pipeline = PipelineController(settings: settings, notifier: notifier)
        self.channelHealth = ChannelHealthController(
            notifier: notifier,
            debounceSeconds: { [settings] in settings.asymmetricSilenceWarningSeconds },
            indicatorEnabled: { [settings] in settings.perChannelIndicatorEnabled },
        )
        self.liveTranscription = LiveTranscriptionCoordinator(
            captions: liveCaptions,
            liveEnabled: { [settings] in settings.liveTranscriptionEnabled },
            engineSupportsLive: { [settings] in settings.transcriptionEngine.supportsLiveTranscription },
            verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
        )

        #if !APPSTORE
            // Not trailing-closure: `isEnabled` is the first param (the other two
            // have defaults), so a trailing closure would bind to `rotateToken`.
            // swiftlint:disable:next trailing_closure
            self.rpcController = RPCServerController(isEnabled: { [settings] in settings.debugRPCEnabled })

            // E2E hook: force a per-channel flag on at launch so a driver
            // script can assert the menu-bar red-tint pipeline end-to-end
            // without orchestrating real audio. Only honoured in non-AppStore
            // builds and only when explicitly enabled via env var. The driver
            // is also expected to set `MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1`
            // so an auto-watch state transition doesn't clear the flag at +3 s
            // through the regular `channelHealth.stop()` path.
            let env = ProcessInfo.processInfo.environment
            channelHealth.applyForcedFlagsForE2E(
                micSilent: env["MEETINGTRANSCRIBER_DEBUG_FORCE_MIC_SILENT"] == "1",
                appSilent: env["MEETINGTRANSCRIBER_DEBUG_FORCE_APP_SILENT"] == "1",
                recordingSilent: env["MEETINGTRANSCRIBER_DEBUG_FORCE_RECORDING_SILENT"] == "1",
            )
        #endif

        // Bring engines in line with the current settings up front so the
        // first transcription doesn't run against stale defaults, then
        // start observing for runtime changes.
        syncLanguageSettings()
        observeEngineSettings()
        liveTranscription.beginPrewarm { [weak self] in self?.activeTranscriptionEngine }
        // Wire the active-engine source (post stored-property init so the
        // `[weak self]` engine closure is valid). The pipeline is rebuilt
        // lazily on the first watch/enqueue, never during init.
        pipeline.activate { [weak self] in self?.activeTranscriptionEngine }

        #if !APPSTORE
            // Launch gate (env var OR setting) + the settings observer now live
            // in RPCServerController.activate; AppState only supplies the wired
            // server. The closure is set here (post stored-property init) so it
            // can capture self.
            rpcController.activate { [weak self] in self?.buildDebugRPCServer() }

            PersistentDiagnosticLog.cleanup()
            do {
                self.persistentLogStreamer = try PersistentDiagnosticLog.startForToday()
            } catch {
                Logger(subsystem: AppPaths.logSubsystem, category: "AppState")
                    .error("persistent_log_streamer_failed_to_start error=\(error.localizedDescription, privacy: .public)")
                self.persistentLogStreamer = nil
            }
            // Stop the streamer cleanly when the app terminates so the file
            // handle flushes and the child `log` process exits. Done via
            // NotificationCenter rather than a SwiftUI `.onReceive` so the
            // observer doesn't churn through the SwiftUI modifier-chain
            // `#if APPSTORE` minefield.
            // AppState lives for the entire process lifetime, so leaking
            // this notification observer until app exit is intentional —
            // there's no point removing it in a deinit that won't run.
            // swiftlint:disable:next discarded_notification_center_observer
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main,
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stopPersistentLogStreamer()
                }
            }
        #endif
    }

    #if !APPSTORE
        /// Stop the persistent log streamer cleanly. Called from the
        /// `NSApplication.willTerminateNotification` handler.
        func stopPersistentLogStreamer() {
            persistentLogStreamer?.stop()
            persistentLogStreamer = nil
        }
    #endif

    #if !APPSTORE
        /// Build a fully-wired debug RPC server (state snapshot + speaker-DB
        /// actions + skip-naming + file-enqueue closures). `RPCServerController`
        /// owns when to start/stop it; this just constructs it.
        func buildDebugRPCServer() -> DebugRPCServer {
            let snapshot: () -> RPCStateSnapshot = { [weak self] in
                self?.rpcStateSnapshot() ?? RPCStateSnapshot.empty
            }
            let skipNaming: () -> Void = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    // Snapshot the pending job IDs and iterate the snapshot.
                    // Avoids infinite-loop hazard if completeSpeakerNaming
                    // ever short-circuits without transitioning state (e.g.
                    // missing speakerNamingDataByJob entry → early return,
                    // pending list unchanged) — observed live during E2E
                    // when the data dictionary was already cleared by an
                    // earlier skip race.
                    let pendingIDs = self.pipeline.queue.pendingSpeakerNamingJobs.map(\.id)
                    for jobID in pendingIDs {
                        self.pipeline.queue.completeSpeakerNaming(jobID: jobID, result: .skipped)
                    }
                }
            }
            // RPC counterpart to the NSOpenPanel "Open from Recording" flow.
            // Validates the file exists (RPC layer returns 400 on `false`),
            // then routes through the same `enqueueFiles` entry point the
            // menu uses, so the import code path is identical.
            let enqueueFile: (URL) -> Bool = { [weak self] url in
                guard let self, FileManager.default.fileExists(atPath: url.path) else { return false }
                Task { @MainActor in self.pipeline.enqueueFiles([url]) }
                return true
            }
            let enqueueFilesRPC: ([URL]) -> Int = { [weak self] urls in
                self?.pipeline.enqueueExistingFiles(urls) ?? 0
            }
            return DebugRPCServer(
                snapshot: snapshot,
                speakerActions: makeSpeakerDBActions(),
                skipNaming: skipNaming,
                enqueueFile: enqueueFile,
                enqueueFiles: enqueueFilesRPC,
            )
        }
    #endif

    /// The active transcription engine based on the current settings.
    var activeTranscriptionEngine: any TranscribingEngine {
        switch settings.transcriptionEngine {
        case .parakeet:
            parakeetEngine

        case .qwen3:
            if #available(macOS 15, *) {
                qwen3Engine
            } else {
                whisperKit // Fallback (should not happen -- UI prevents selection)
            }

        case .whisperKit:
            whisperKit
        }
    }

    // MARK: - Derived properties

    var isWatching: Bool {
        watchLoop?.isActive == true && watchLoop?.isManualRecording == false
    }

    /// True when the caption-bar overlay should be visible: live transcription
    /// toggle on, engine implements `transcribeSamples`, and an actual
    /// recording is in progress.
    var shouldShowLiveCaptions: Bool {
        settings.liveTranscriptionEnabled
            && settings.transcriptionEngine.supportsLiveTranscription
            && watchLoop?.state == .recording
    }

    var currentBadge: BadgeKind {
        BadgeKind.compute(
            watchLoopActive: watchLoop?.isActive == true,
            watchLoopState: watchLoop?.state ?? .idle,
            transcriberState: watchLoop?.transcriberState ?? .idle,
            activeJobState: pipeline.queue.activeJobs.first?.state,
            updateAvailable: updateChecker.availableUpdate != nil,
            permissionProblem: permissions.health?.isHealthy == false,
        )
    }

    var currentStateLabel: String {
        if let loop = watchLoop, loop.isActive {
            return loop.transcriberState.label
        }
        return "Idle"
    }

    /// Whether the live permission health check currently reports a problem.
    /// Hoisted out of the SwiftUI menu-bar body: resolving the
    /// `permissions.health?.isHealthy == false` chain inline pushed that body's
    /// type-check over the 300 ms budget on slower CI runners. Reading it as a
    /// named `Bool` property keeps the body cheap.
    var hasPermissionProblem: Bool {
        permissions.health?.isHealthy == false
    }

    /// Single-member accessors that keep the menu-bar body's type-check cheap.
    /// Reading `pipeline.queue.…` directly in that body adds a member-resolution
    /// layer per use that pushed its type-check over budget on slower CI runners
    /// (the same footgun `hasPermissionProblem` / `micSilentOverlay` address).
    /// The body reads these named props instead; the chains resolve here.
    var pipelineQueue: PipelineQueue {
        pipeline.queue
    }

    var hasPendingSpeakerNamingJobs: Bool {
        !pipeline.queue.pendingSpeakerNamingJobs.isEmpty
    }

    /// Menu-bar **top-half** red tint: mic channel silent, OR both channels
    /// silent (`recordingSilentActive` paints both halves). Hoisted out of the
    /// menu-bar body for the same type-check-budget reason as
    /// `hasPermissionProblem` — reading two `channelHealth.*` flags through the
    /// sub-controller inline is more than the body can afford on slow CI.
    var micSilentOverlay: Bool {
        channelHealth.micSilentActive || channelHealth.recordingSilentActive
    }

    /// Menu-bar **bottom-half** red tint: app-audio channel silent, OR both
    /// channels silent. See `micSilentOverlay`.
    var appSilentOverlay: Bool {
        channelHealth.appSilentActive || channelHealth.recordingSilentActive
    }

    private static let isoFormatter = ISO8601DateFormatter()

    var currentStatus: TranscriberStatus? {
        guard let loop = watchLoop, loop.isActive else { return nil }

        let meeting: MeetingInfo? = if let manual = loop.manualRecordingInfo {
            MeetingInfo(
                app: manual.appName,
                title: manual.title,
                pid: Int(manual.pid),
            )
        } else {
            loop.currentMeeting.map { meeting in
                MeetingInfo(
                    app: meeting.pattern.appName,
                    title: meeting.windowTitle,
                    pid: Int(meeting.windowPID),
                )
            }
        }

        return TranscriberStatus(
            version: 1,
            timestamp: Self.isoFormatter.string(from: Date()),
            state: loop.transcriberState,
            detail: loop.detail,
            meeting: meeting,
            protocolPath: nil,
            error: loop.lastError,
            audioPath: nil,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
        )
    }

    // MARK: - Live transcription factory

    /// Build the `recorderFactory` closure for `WatchLoop`. Returns a fresh
    /// `DualSourceRecorder` on each invocation; when `liveTranscriptionEnabled`
    /// is on AND the active engine supports `transcribeSamples`, also installs
    /// mic + app live sinks that pipe captured buffers to the
    /// `LiveTranscriptionController`. PoC scope — see
    /// `LiveTranscriptionController` doc for what's logged.
    private func makeRecorderFactory() -> @MainActor () -> any RecordingProvider {
        { [weak self] in
            let recorder = DualSourceRecorder()
            self?.liveTranscription.attachSinks(to: recorder)
            return recorder
        }
    }

    // MARK: - Start / Stop

    func toggleWatching() {
        if let loop = watchLoop, loop.isManualRecording { return }
        if let loop = watchLoop, loop.isActive {
            loop.stop()
            watchLoop = nil
        } else {
            Task { @MainActor in
                _ = await Permissions.ensureMicrophoneAccess()

                syncLanguageSettings()
                pipeline.rebuild()

                let detector: any MeetingDetecting = PowerAssertionDetector()

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
            _ = await Permissions.ensureMicrophoneAccess()

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

    // MARK: - Channel Health Monitor

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

    // MARK: - Engine Settings

    /// Push current language/vocabulary settings into the active engine.
    /// Idempotent — each branch only writes when the value actually differs,
    /// so unchanged settings don't churn the engine's `@Observable` watchers.
    private func syncLanguageSettings() {
        switch settings.transcriptionEngine {
        case .whisperKit:
            let next = settings.whisperLanguageOrNil
            if whisperKit.language != next { whisperKit.language = next }

        case .parakeet:
            let nextVocab = settings.customVocabularyPath
            if parakeetEngine.customVocabularyPath != nextVocab { parakeetEngine.customVocabularyPath = nextVocab }
            let nextLang = settings.parakeetLanguageOrNil
            if parakeetEngine.language != nextLang { parakeetEngine.language = nextLang }

        case .qwen3:
            if #available(macOS 15, *) {
                let next = settings.qwen3LanguageOrNil
                if qwen3Engine.language != next { qwen3Engine.language = next }
            }
        }
    }

    /// `withObservationTracking` is one-shot — re-arm after each fire so the
    /// AppState reacts to every settings change, not just the first one.
    /// Same self-re-arming pattern the concern controllers use for their observers.
    private func observeEngineSettings() {
        withObservationTracking {
            _ = settings.transcriptionEngine
            _ = settings.whisperLanguage
            _ = settings.customVocabularyPath
            _ = settings.parakeetLanguage
            _ = settings.qwen3Language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncLanguageSettings()
                self.observeEngineSettings()
            }
        }
    }
}

// MARK: - SilentNotifier

/// No-op notifier for CLI targets and tests that don't need notifications.
struct SilentNotifier: AppNotifying {
    func notify(title _: String, body _: String) {}
}
