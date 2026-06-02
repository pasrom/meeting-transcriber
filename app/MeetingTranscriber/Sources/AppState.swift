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

/// Observable ViewModel that owns all business state and derived UI properties.
///
/// Extracted from `MeetingTranscriberApp` so that:
/// - Badge/watching logic is testable without instantiating the `@main` App struct.
/// - `BadgeKind.compute(...)` can be called directly in tests.
@Observable
@MainActor
final class AppState { // swiftlint:disable:this type_body_length
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
    var pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker
    var selectedNamingJobID: UUID?

    /// Live TCC permission-health concern, extracted into its own controller.
    /// `currentBadge` composes its `health` into the `.error` state.
    let permissions: PermissionsController

    /// True while the **mic** channel is silent and the app channel is carrying
    /// speech continuously for `settings.asymmetricSilenceWarningSeconds`. Drives
    /// the menu-bar **top-half** red tint. Latches until the dead channel recovers
    /// (or recording stops). At most one of `micSilentActive` / `appSilentActive`
    /// is true at a time — the monitor's channel-switch path resets when roles flip.
    var micSilentActive: Bool = false

    /// True while the **app-audio** channel is silent and the mic is carrying
    /// speech continuously for `settings.asymmetricSilenceWarningSeconds`. Drives
    /// the menu-bar **bottom-half** red tint.
    var appSilentActive: Bool = false

    /// True while **both** capture channels have been below the silence
    /// threshold continuously for `settings.asymmetricSilenceWarningSeconds`
    /// — the failure mode `ChannelHealthMonitor` intentionally ignores
    /// (symmetric silence). Drives the menu-bar **full red** waveform
    /// (both halves tinted simultaneously).
    var recordingSilentActive: Bool = false

    /// Pure state machine driven by the 10-Hz level poll while recording. Lives
    /// here (not on WatchLoop) so its lifecycle outlasts a single recording —
    /// observers of `micSilentActive` / `appSilentActive` keep their identity across the
    /// detect → record → process state churn.
    @ObservationIgnored private var channelHealthMonitor = ChannelHealthMonitor()

    /// Sibling monitor that catches the symmetric-silence case
    /// `ChannelHealthMonitor` intentionally skips. Shares the same
    /// debounce threshold; lifecycle managed alongside the channel-health
    /// monitor in `startChannelHealthMonitoring` / `stopChannelHealthMonitoring`.
    @ObservationIgnored private var silentRecordingMonitor = SilentRecordingMonitor()

    @ObservationIgnored private var levelMonitorTask: Task<Void, Never>?

    /// PoC live-transcription controller. Lazily created on first recording
    /// start where `settings.liveTranscriptionEnabled` is true AND the active
    /// engine is Parakeet (other engines silently no-op via
    /// `TranscriptionError.streamingNotSupported`). Kept across recordings so
    /// engine + VAD models stay warm.
    @ObservationIgnored private var liveTranscriptionController: LiveTranscriptionController?

    /// Observable state for the live caption overlay. Always present (the
    /// `LiveCaptionsOverlay` window observes this); content is only populated
    /// when live transcription is on AND a recording is active.
    let liveCaptions: LiveCaptionsState = .init()

    #if !APPSTORE
        /// Lazy-started debug RPC server. Only constructed if the env var is
        /// set — otherwise `nil` and zero overhead.
        var debugRPCServer: DebugRPCServer?

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
        self.pipelineQueue = PipelineQueue()
        self.channelHealthMonitor = ChannelHealthMonitor(
            debounceSeconds: settings.asymmetricSilenceWarningSeconds,
        )
        self.silentRecordingMonitor = SilentRecordingMonitor(
            debounceSeconds: settings.asymmetricSilenceWarningSeconds,
        )

        #if !APPSTORE
            // E2E hook: force a per-channel flag on at launch so a driver
            // script can assert the menu-bar red-tint pipeline end-to-end
            // without orchestrating real audio. Only honoured in non-AppStore
            // builds and only when explicitly enabled via env var. The driver
            // is also expected to set `MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1`
            // so an auto-watch state transition doesn't clear the flag at +3 s
            // through the regular `stopChannelHealthMonitoring()` path.
            let env = ProcessInfo.processInfo.environment
            if env["MEETINGTRANSCRIBER_DEBUG_FORCE_MIC_SILENT"] == "1" {
                micSilentActive = true
            }
            if env["MEETINGTRANSCRIBER_DEBUG_FORCE_APP_SILENT"] == "1" {
                appSilentActive = true
            }
            if env["MEETINGTRANSCRIBER_DEBUG_FORCE_RECORDING_SILENT"] == "1" {
                recordingSilentActive = true
            }
        #endif

        // Bring engines in line with the current settings up front so the
        // first transcription doesn't run against stale defaults, then
        // start observing for runtime changes.
        syncLanguageSettings()
        observeEngineSettings()
        setupLiveTranscriptionPrewarm()

        #if !APPSTORE
            // Env var force-enables at launch only — preserves back-compat with
            // scripts/test_rpc.sh and CI. After init, settings.debugRPCEnabled
            // is the sole driver, so toggling off mid-session works even when
            // the env var was set at launch.
            if DebugRPCServer.enabled || settings.debugRPCEnabled {
                startDebugRPCServer()
            }
            observeDebugRPCSetting()

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
        /// Reconcile the debug RPC server with the current setting.
        ///
        /// Called only from the settings-driven `observeDebugRPCSetting` path
        /// (init has its own gate). On a toggle off → on we rotate the bearer
        /// token before starting the listener: that way any token an attacker
        /// scraped while the server was previously running is invalidated by
        /// the act of turning it off and on again — the same gesture a user
        /// already performs to "reset" the feature.
        func applyDebugRPCSetting() {
            if settings.debugRPCEnabled, debugRPCServer == nil {
                DebugRPCServer.rotateToken()
                startDebugRPCServer()
            } else if !settings.debugRPCEnabled, let server = debugRPCServer {
                server.stop()
                debugRPCServer = nil
            }
        }

        private func startDebugRPCServer() {
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
                    let pendingIDs = self.pipelineQueue.pendingSpeakerNamingJobs.map(\.id)
                    for jobID in pendingIDs {
                        self.pipelineQueue.completeSpeakerNaming(jobID: jobID, result: .skipped)
                    }
                }
            }
            // RPC counterpart to the NSOpenPanel "Open from Recording" flow.
            // Validates the file exists (RPC layer returns 400 on `false`),
            // then routes through the same `enqueueFiles` entry point the
            // menu uses, so the import code path is identical.
            let enqueueFile: (URL) -> Bool = { [weak self] url in
                guard let self, FileManager.default.fileExists(atPath: url.path) else { return false }
                Task { @MainActor in self.enqueueFiles([url]) }
                return true
            }
            let enqueueFilesRPC: ([URL]) -> Int = { [weak self] urls in
                self?.enqueueExistingFiles(urls) ?? 0
            }
            let server = DebugRPCServer(
                snapshot: snapshot,
                speakerActions: makeSpeakerDBActions(),
                skipNaming: skipNaming,
                enqueueFile: enqueueFile,
                enqueueFiles: enqueueFilesRPC,
            )
            server.start()
            debugRPCServer = server
        }

        /// `withObservationTracking` is one-shot — re-arm after each fire so
        /// the AppState reacts to every toggle of `settings.debugRPCEnabled`,
        /// not just the first one.
        private func observeDebugRPCSetting() {
            withObservationTracking {
                _ = settings.debugRPCEnabled
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyDebugRPCSetting()
                    self.observeDebugRPCSetting()
                }
            }
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
            activeJobState: pipelineQueue.activeJobs.first?.state,
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
            guard let self else { return recorder }
            if self.settings.liveTranscriptionEnabled,
               self.settings.transcriptionEngine.supportsLiveTranscription,
               let controller = self.ensureLiveTranscriptionController() {
                controller.reset()
                recorder.micLiveSink = controller.micSink
                recorder.appLiveSink = controller.appSink
            }
            return recorder
        }
    }

    /// Lazily create + warm the live transcription controller against the
    /// currently-active engine. Safe to call repeatedly — `prepare()` is
    /// idempotent (engines dedupe concurrent `loadModel` calls). When the
    /// transcription-engine setting changes, the controller is invalidated
    /// via `observeEngineSettings` so the next call rebuilds against the
    /// new engine.
    ///
    /// Returns nil when the active engine doesn't conform to
    /// `StreamingTranscribingEngine` — the static equivalent of the
    /// `supportsLiveTranscription` enum-level gate. Both `prewarm…` and
    /// `makeRecorderFactory` callers already check that gate before
    /// invoking this, so a nil return here only happens if a regression
    /// breaks one of those guards.
    private func ensureLiveTranscriptionController() -> LiveTranscriptionController? {
        if let existing = liveTranscriptionController { return existing }
        guard let streamingEngine = activeTranscriptionEngine as? any StreamingTranscribingEngine else {
            return nil
        }
        let controller = LiveTranscriptionController(
            engine: streamingEngine,
            vad: FluidVAD(threshold: 0.5),
            captions: liveCaptions,
        ) { [weak self] in
            self?.settings.verboseDiagnostics ?? false
        }
        liveTranscriptionController = controller
        Task { @MainActor in await controller.prepare() }
        return controller
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
                pipelineQueue = makePipelineQueue()

                let detector: any MeetingDetecting = PowerAssertionDetector()

                let loop = WatchLoop(
                    detector: detector,
                    recorderFactory: makeRecorderFactory(),
                    pipelineQueue: pipelineQueue,
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

                configurePipelineCallbacks()

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

            ensurePipelineQueue()

            let loop = WatchLoop(
                recorderFactory: makeRecorderFactory(),
                pipelineQueue: pipelineQueue,
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

    /// Filters `urls` to files that currently exist on disk, forwards them to
    /// `enqueueFiles`, and returns the existing count. RPC-friendly entry
    /// point; nil-callers (weak self) treat absent app as 0-enqueued.
    @discardableResult
    func enqueueExistingFiles(_ urls: [URL]) -> Int {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return 0 }
        enqueueFiles(existing)
        return existing.count
    }

    func enqueueFiles(_ urls: [URL]) {
        ensurePipelineQueue()

        let resolution = PairedRecordingResolver.resolve(urls: urls)

        for group in resolution.paired {
            let sidecar = RecordingSidecar.read(
                fromDirectory: group.directory,
                basename: group.stem,
            )
            let title = sidecar?.title ?? group.stem
            let appName = sidecar?.appName ?? "File"
            let micDelay = sidecar?.micDelaySeconds ?? 0
            let participants = sidecar?.participants ?? []

            // For paired groups: pass `group.mix` directly (nil when only app+mic
            // were selected — the pipeline mixes app+mic into the workdir cache
            // on the fly, no persistent `_mix.wav` is written to the user's
            // recordings dir).
            let job = PipelineJob(
                meetingTitle: title, appName: appName,
                mixPath: group.mix, appPath: group.app, micPath: group.mic,
                micDelay: micDelay, participants: participants,
            )
            pipelineQueue.enqueue(job)
        }

        for url in resolution.singletons {
            let title = url.deletingPathExtension().lastPathComponent
            let job = PipelineJob(
                meetingTitle: title,
                appName: "File",
                mixPath: url,
                appPath: nil,
                micPath: nil,
                micDelay: 0,
            )
            pipelineQueue.enqueue(job)
        }
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
                self?.startChannelHealthMonitoring()

            case .error:
                if let err = loop?.lastError {
                    notifier.notify(title: "Error", body: err)
                }
                self?.stopChannelHealthMonitoring()

            default:
                self?.stopChannelHealthMonitoring()
            }
        }
    }

    /// Rebuilds `channelHealthMonitor` with the current settings-driven debounce.
    /// Called from `startChannelHealthMonitoring` and exposed as a test seam so
    /// `ChannelHealthIntegrationTests` can simulate the "user changed threshold
    /// between recordings" path without spinning up the polling Task.
    func simulateStartChannelHealthMonitoringForTests() {
        rebuildChannelHealthMonitor()
    }

    private func rebuildChannelHealthMonitor() {
        channelHealthMonitor = ChannelHealthMonitor(
            debounceSeconds: settings.asymmetricSilenceWarningSeconds,
        )
        silentRecordingMonitor = SilentRecordingMonitor(
            debounceSeconds: settings.asymmetricSilenceWarningSeconds,
        )
    }

    /// Starts a ~10 Hz polling task that feeds the active recorder's per-channel
    /// levels into `channelHealthMonitor` and flips `micSilentActive` /
    /// `appSilentActive` based on the resulting events. Idempotent: calling while already running
    /// is a no-op. Skips entirely when the master toggle is off.
    private func startChannelHealthMonitoring() {
        guard settings.perChannelIndicatorEnabled else { return }
        guard levelMonitorTask == nil else { return }
        rebuildChannelHealthMonitor()
        levelMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tickChannelHealth()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func tickChannelHealth() {
        guard let recorder = watchLoop?.activeRecorder else { return }
        applyChannelHealthTick(recorder: recorder, now: Date())
    }

    /// Internal test seam: drives one polling tick against an arbitrary
    /// recorder + clock. Production code uses `tickChannelHealth()` which
    /// reads the active recorder + wall clock.
    @discardableResult
    func applyChannelHealthTick(
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

    /// Stops the polling task and resets the monitor + UI flag. Called when
    /// recording ends or an error transition happens.
    private func stopChannelHealthMonitoring() {
        levelMonitorTask?.cancel()
        levelMonitorTask = nil
        channelHealthMonitor.reset()
        silentRecordingMonitor.reset()
        micSilentActive = false
        appSilentActive = false
        recordingSilentActive = false
    }

    // MARK: - Pipeline

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
    /// Mirrors the `observeDebugRPCSetting` pattern.
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

    /// Eagerly load the FluidVAD + Parakeet models when the live-transcription
    /// toggle flips on (or is already on at launch with the right engine), so
    /// the first utterance after the recorder starts doesn't pay the cold-load
    /// cost (a few seconds for the first call to `engine.loadModel()` + VAD
    /// init). No-op when the conditions aren't met. Idempotent — the engines
    /// dedupe concurrent `loadModel` calls.
    private func prewarmLiveTranscriptionIfEligible() {
        guard settings.liveTranscriptionEnabled,
              settings.transcriptionEngine.supportsLiveTranscription
        else { return }
        _ = ensureLiveTranscriptionController()
    }

    /// Initial pre-warm of the live-transcription controller (when enabled +
    /// the active engine supports streaming) plus a re-arming
    /// `withObservationTracking` watcher on `liveTranscriptionEnabled` and
    /// `transcriptionEngine`. On every change, drop the cached controller so
    /// the next `ensureLiveTranscriptionController()` call rebuilds against
    /// the (possibly new) `activeTranscriptionEngine` and re-warms the right
    /// engine.
    ///
    /// Engine changes take effect on the **next** recording. Switching the
    /// engine mid-recording deallocates the controller (its sinks capture
    /// `[weak self]`), buffers from the running recorder no longer reach any
    /// engine, and the live overlay goes silent until the recording stops and
    /// a new one starts. Live mid-recording engine swap is a deferred follow-up
    /// — see PR #318 limitations.
    ///
    /// Combined into a single method (rather than two init-body calls) so the
    /// AppState init's type-check stays under the 300 ms `expression_type_check`
    /// lint budget. Same recurring flake as `feedback_local_verify_before_push`
    /// — the compiler's constraint solver gets slower with every method call
    /// inside a long initializer.
    private func setupLiveTranscriptionPrewarm() {
        prewarmLiveTranscriptionIfEligible()
        withObservationTracking {
            _ = settings.liveTranscriptionEnabled
            _ = settings.transcriptionEngine
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.liveTranscriptionController = nil
                self.setupLiveTranscriptionPrewarm()
            }
        }
    }

    func ensurePipelineQueue() {
        guard pipelineQueue.engine == nil else { return }
        pipelineQueue = makePipelineQueue()
        configurePipelineCallbacks()
    }

    /// One-stop FluidDiarizer instantiation. Captures the current tuning
    /// fields from settings so both the global-mode factory and the
    /// per-job mode-override factory stay in sync. Tuning only affects
    /// `.offline` mode, but is harmless when passed to `.sortformer`.
    private func makeFluidDiarizer(mode: DiarizerMode) -> FluidDiarizer {
        FluidDiarizer(
            mode: mode,
            tuning: OfflineDiarizerTuning(
                clusterThreshold: settings.clusterThreshold,
                warmStartFa: settings.warmStartFa,
                warmStartFb: settings.warmStartFb,
                minSegmentDurationSeconds: settings.minSegmentDurationSeconds,
                excludeOverlap: settings.excludeOverlap,
            ),
        )
    }

    func makePipelineQueue() -> PipelineQueue {
        let queue = PipelineQueue(
            engine: activeTranscriptionEngine,
            diarizationFactory: { [self] in makeFluidDiarizer(mode: settings.diarizerMode) },
            diarizationFactoryWithMode: { [self] mode in makeFluidDiarizer(mode: mode) },
            protocolGeneratorFactory: { [self] in makeProtocolGenerator() },
            outputDir: settings.effectiveOutputDir,
            diarizeEnabled: settings.diarize,
            numSpeakers: settings.numSpeakers,
            micLabel: settings.micName,
            speakerMatcherFactory: { SpeakerMatcher() },
            vadConfig: settings.vadEnabled ? VADConfig(threshold: settings.vadThreshold) : nil,
            recognitionStatsLog: RecognitionStatsLog(),
        )
        queue.loadSnapshot()
        // Fire-and-forget: dir scan + per-file attr probes run off-main so
        // app startup (and the first call to `enqueueFiles`) isn't blocked
        // by a slow filesystem. Recovered jobs appear in `queue.jobs` once
        // the scan returns.
        Task { await queue.recoverOrphanedRecordings() }
        queue.refreshKnownSpeakerNames()
        return queue
    }

    func makeProtocolGenerator() -> (any ProtocolGenerating)? {
        switch settings.protocolProvider {
        #if !APPSTORE
            case .claudeCLI:
                ClaudeCLIProtocolGenerator(claudeBin: settings.claudeBin, language: settings.protocolLanguage)
        #endif

        case .openAICompatible:
            OpenAIProtocolGenerator(
                endpoint: URL(string: settings.openAIEndpoint)
                    // swiftlint:disable:next force_unwrapping
                    ?? URL(string: "http://localhost:11434/v1/chat/completions")!,
                model: settings.openAIModel,
                language: settings.protocolLanguage,
                apiKey: settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey,
            )

        case .none:
            nil
        }
    }

    func configurePipelineCallbacks() {
        pipelineQueue.onJobStateChange = { [notifier] job, _, newState in
            switch newState {
            case .done:
                let title = job.protocolPath != nil ? "Protocol Ready" : "Transcript Saved"
                notifier.notify(title: title, body: job.meetingTitle)

            case .error:
                if let err = job.error {
                    notifier.notify(title: "Error", body: err)
                }

            default:
                break
            }
        }
    }
}

// MARK: - SilentNotifier

/// No-op notifier for CLI targets and tests that don't need notifications.
struct SilentNotifier: AppNotifying {
    func notify(title _: String, body _: String) {}
}
