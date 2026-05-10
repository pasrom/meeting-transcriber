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
    var pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker
    var selectedNamingJobID: UUID?
    var permissionHealth: HealthCheckResult?

    #if !APPSTORE
        /// Lazy-started debug RPC server. Only constructed if the env var is
        /// set — otherwise `nil` and zero overhead.
        var debugRPCServer: DebugRPCServer?

        /// Background `log stream` subprocess that mirrors our subsystems to
        /// `~/Library/Logs/MeetingTranscriber/diagnostics-YYYY-MM-DD.log`.
        /// Survives longer than OSLogStore retention (~1h for `.info`).
        private(set) var persistentLogStreamer: PersistentDiagnosticLog.Streamer?
    #endif

    // MARK: - Init

    init(
        settings: AppSettings = AppSettings(),
        whisperKit: WhisperKitEngine? = nil,
        parakeetEngine: ParakeetEngine? = nil,
        qwen3Engine: AnyObject? = nil,
        notifier: any AppNotifying = SilentNotifier(),
        updateChecker: UpdateChecker? = nil,
    ) {
        self.settings = settings
        self.whisperKit = whisperKit ?? WhisperKitEngine()
        self.parakeetEngine = parakeetEngine ?? ParakeetEngine()
        if #available(macOS 15, *) {
            self._qwen3Engine = (qwen3Engine as? Qwen3AsrEngine) ?? Qwen3AsrEngine()
        } else {
            self._qwen3Engine = nil
        }
        self.notifier = notifier
        self.updateChecker = updateChecker ?? UpdateChecker()
        self.pipelineQueue = PipelineQueue()

        // Bring engines in line with the current settings up front so the
        // first transcription doesn't run against stale defaults, then
        // start observing for runtime changes.
        syncLanguageSettings()
        observeEngineSettings()

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
                    // Drain all currently-pending naming jobs. Each
                    // completeSpeakerNaming call transitions the first
                    // pending job out of .speakerNamingPending
                    // synchronously, so the loop terminates.
                    while !self.pipelineQueue.pendingSpeakerNamingJobs.isEmpty {
                        self.pipelineQueue.completeSpeakerNaming(result: .skipped)
                    }
                }
            }
            let server = DebugRPCServer(
                snapshot: snapshot,
                speakerActions: makeSpeakerDBActions(),
                skipNaming: skipNaming,
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

    var currentBadge: BadgeKind {
        BadgeKind.compute(
            watchLoopActive: watchLoop?.isActive == true,
            watchLoopState: watchLoop?.state ?? .idle,
            transcriberState: watchLoop?.transcriberState ?? .idle,
            activeJobState: pipelineQueue.activeJobs.first?.state,
            updateAvailable: updateChecker.availableUpdate != nil,
            permissionProblem: permissionHealth?.isHealthy == false,
        )
    }

    var currentStateLabel: String {
        if let loop = watchLoop, loop.isActive {
            return loop.transcriberState.label
        }
        return "Idle"
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

    // MARK: - Start / Stop

    func toggleWatching() {
        if let loop = watchLoop, loop.isManualRecording { return }
        if let loop = watchLoop, loop.isActive {
            loop.stop()
            watchLoop = nil
        } else {
            // swiftlint:disable:next closure_body_length
            Task { @MainActor in
                _ = await Permissions.ensureMicrophoneAccess()

                syncLanguageSettings()
                pipelineQueue = makePipelineQueue()

                let detector: any MeetingDetecting = PowerAssertionDetector()

                let loop = WatchLoop(
                    detector: detector,
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

                loop.onStateChange = { [weak loop, notifier] _, newState in
                    switch newState {
                    case .recording:
                        if let meeting = loop?.currentMeeting {
                            notifier.notify(
                                title: "Meeting Detected",
                                body: "Recording: \(meeting.windowTitle)",
                            )
                        }

                    case .error:
                        if let err = loop?.lastError {
                            notifier.notify(title: "Error", body: err)
                        }

                    default:
                        break
                    }
                }

                if let health = permissionHealth {
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
                recorderFactory: { DualSourceRecorder() },
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

            // Use cached health check result instead of live probe
            if let health = permissionHealth {
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

    func enqueueFiles(_ urls: [URL]) {
        ensurePipelineQueue()

        for url in urls {
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

    // MARK: - Permission Health

    func handlePermissionHealth(_ result: HealthCheckResult) {
        let previousProblems = permissionHealth?.problems ?? []
        permissionHealth = result
        let line = "[PermissionHealthCheck] screen=\(result.screenRecording) mic=\(result.microphone) " +
            "ax=\(result.accessibility) healthy=\(result.isHealthy) problems=\(result.problems)"
        PermissionHealthCheck.debugLog(line)

        let problems = result.problems
        if !problems.isEmpty, problems != previousProblems {
            PermissionHealthCheck.debugLog("[PermissionHealthCheck] Sending notification: \(result.notificationBody)")
            notifier.notify(
                title: "Permission Problem",
                body: result.notificationBody,
            )
        }
    }

    /// Timestamp of the last completed `checkPermissions()` run. Used to debounce repeated
    /// calls triggered by `NSApplication.didBecomeActiveNotification` so the 500 ms mic
    /// probe doesn't churn the audio HAL on every Cmd-Tab.
    private var lastPermissionCheckAt: Date?

    /// Run the live permission health check.
    ///
    /// - Parameter minimumInterval: if non-nil, skip the run when the last completed check
    ///   happened less than `minimumInterval` seconds ago. The initial startup call passes
    ///   `nil` so it always runs; the `didBecomeActive` handler passes a small value to
    ///   avoid HAL churn on rapid re-activations.
    func checkPermissions(minimumInterval: TimeInterval? = nil) async {
        if let minimumInterval, let last = lastPermissionCheckAt,
           Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        let result = await PermissionHealthCheck.runLive()
        lastPermissionCheckAt = Date()
        handlePermissionHealth(result)
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
            let next = settings.customVocabularyPath
            if parakeetEngine.customVocabularyPath != next {
                parakeetEngine.customVocabularyPath = next
            }

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
            _ = settings.qwen3Language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncLanguageSettings()
                self.observeEngineSettings()
            }
        }
    }

    func ensurePipelineQueue() {
        guard pipelineQueue.engine == nil else { return }
        pipelineQueue = makePipelineQueue()
        configurePipelineCallbacks()
    }

    func makePipelineQueue() -> PipelineQueue {
        let queue = PipelineQueue(
            engine: activeTranscriptionEngine,
            diarizationFactory: { [self] in FluidDiarizer(mode: settings.diarizerMode) },
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
        queue.recoverOrphanedRecordings()
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
