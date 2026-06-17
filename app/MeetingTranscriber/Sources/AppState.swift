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
/// (`engines`, `watching`, `pipeline`, `permissions`, `channelHealth`,
/// `liveTranscription`, `rpcController`) and exposes the derived UI properties
/// (badge, status label) the menu-bar scene binds to. It wires the controllers
/// together rather than owning their state — new concern state belongs in a
/// controller, not here.
///
/// Extracted from `MeetingTranscriberApp` so badge/watching logic and
/// `BadgeKind.compute(...)` are testable without the `@main` App struct.
@Observable
@MainActor
final class AppState {
    // MARK: - Dependencies

    let settings: AppSettings
    private let notifier: any AppNotifying

    // MARK: - State

    var updateChecker: UpdateChecker
    var selectedNamingJobID: UUID?

    /// Transcription-engine concern (the three engine instances, active-engine
    /// selection, and settings → engine language/vocabulary sync), extracted
    /// into its own controller. Read as `engines.activeTranscriptionEngine` by
    /// the pipeline + live-transcription coordinators and `engines.whisperKit`
    /// etc. by the Settings UI + RPC snapshot.
    let engines: EngineController

    /// Watching / recording lifecycle concern (the active `WatchLoop`, the
    /// auto-detect toggle, manual recording start/stop, the recorder factory,
    /// and the state-change handler), extracted into its own controller. It
    /// holds the sibling controllers it reaches across; AppState's derived UI
    /// properties read its `watchLoop`.
    let watching: WatchingController

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
    /// `WatchingController` wires its `start()` / `stop()` to `WatchLoop` state
    /// transitions, and the menu-bar icon + RPC snapshot read its flags.
    let channelHealth: ChannelHealthController

    /// Observable state for the live caption overlay. Always present (the
    /// `LiveCaptionsOverlay` window observes this); content is only populated
    /// when live transcription is on AND a recording is active. Owned here (read
    /// by the overlay window + RPC snapshot) and injected into `liveTranscription`.
    let liveCaptions: LiveCaptionsState = .init()

    /// Live-transcription controller lifecycle (lazy creation against the active
    /// engine, pre-warm, per-recording sink installation), extracted into its own
    /// coordinator. `WatchingController`'s recorder factory delegates sink
    /// installation to it.
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

    private static func makeUpdateChecker() -> UpdateChecker {
        UpdateChecker()
    }

    // MARK: - Init

    init(
        settings: AppSettings = AppState.makeDefaultSettings(),
        notifier: any AppNotifying = SilentNotifier(),
        updateChecker: UpdateChecker? = nil,
    ) {
        // Dependency defaults are resolved through explicitly-typed factory
        // helpers (above) rather than inline `?? SomeType()` expressions (and an
        // inline `AppSettings()` default argument). An inline `@Observable`
        // constructor forces the type-checker to re-solve the dependency's own
        // init constraints at this call site, which pushed this init's
        // body-type-check time toward the 300 ms hard limit enforced in
        // Package.swift. A factory with a declared return type collapses the
        // inference here to a plain function reference. Behaviour is identical.
        self.settings = settings
        self.notifier = notifier
        self.engines = EngineController(settings: settings)
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
            englishStreaming: { [settings] in settings.liveCaptionsEnglishStreaming },
            verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
        )
        self.watching = WatchingController(
            settings: settings,
            notifier: notifier,
            pipeline: pipeline,
            channelHealth: channelHealth,
            permissions: permissions,
            liveTranscription: liveTranscription,
        )

        #if !APPSTORE
            // Not trailing-closure: `isEnabled` is the first param (the other two
            // have defaults), so a trailing closure would bind to `rotateToken`.
            // swiftlint:disable:next trailing_closure
            self.rpcController = RPCServerController(isEnabled: { [settings] in settings.debugRPCEnabled })
        #endif

        // Wire the active-engine source + the watch-start up-front engine sync
        // (post stored-property init so the `[weak self]` closures are valid).
        // `EngineController` does its own up-front sync + reactive observe in its
        // init; these hooks let the pipeline / live-transcription / watch paths
        // reach the active engine and re-sync before the first transcription.
        liveTranscription.beginPrewarm { [weak self] in self?.engines.activeTranscriptionEngine }
        pipeline.activate { [weak self] in self?.engines.activeTranscriptionEngine }
        watching.activate { [weak self] in self?.engines.syncLanguageSettings() }

        #if !APPSTORE
            applyForcedChannelFlagsFromEnvironment()

            // Launch gate (env var OR setting) + the settings observer now live
            // in RPCServerController.activate; AppState only supplies the wired
            // server. The closure is set here (post stored-property init) so it
            // can capture self.
            rpcController.activate { [weak self] in self?.buildDebugRPCServer() }

            PersistentDiagnosticLog.cleanup()
            // Reap any `log stream` children orphaned by a previous crash/SIGKILL
            // (re-parented to launchd) so they can't accumulate across launches.
            // Off the main thread: it shells out to `ps` + waitUntilExit(), which
            // would otherwise stall launch proportional to the process-table size.
            // The reap is deliberately NOT ordered before `startForToday()` — an
            // orphan surviving a few extra ms is benign next to blocking launch,
            // and the new streamer is matched by parent pid so it's never reaped.
            Task.detached(priority: .utility) { PersistentDiagnosticLog.reapOrphans() }
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

        /// E2E hook: force a per-channel silence flag on at launch so a driver
        /// script can assert the menu-bar red-tint pipeline end-to-end without
        /// orchestrating real audio. Only honoured in non-AppStore builds and
        /// only when explicitly enabled via env var. The driver is also expected
        /// to set `MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1` so an auto-watch
        /// state transition doesn't clear the flag at +3 s through the regular
        /// `channelHealth.stop()` path.
        private func applyForcedChannelFlagsFromEnvironment() {
            let env = ProcessInfo.processInfo.environment
            channelHealth.applyForcedFlagsForE2E(
                micSilent: env["MEETINGTRANSCRIBER_DEBUG_FORCE_MIC_SILENT"] == "1",
                appSilent: env["MEETINGTRANSCRIBER_DEBUG_FORCE_APP_SILENT"] == "1",
                recordingSilent: env["MEETINGTRANSCRIBER_DEBUG_FORCE_RECORDING_SILENT"] == "1",
            )
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
            // `/v1/jobs` automation surface: enqueue returning the created job
            // IDs, and per-job status lookup (live job or persisted terminal
            // record) so a headless client can poll a specific job.
            let enqueueReturningIDs: ([URL]) -> [UUID] = { [weak self] urls in
                self?.pipeline.enqueueExistingFilesReturningIDs(urls) ?? []
            }
            let jobStatus: (UUID) -> JobStatusDTO? = { [weak self] id in
                self?.pipeline.jobStatus(forID: id)
            }
            return DebugRPCServer(
                snapshot: snapshot,
                speakerActions: makeSpeakerDBActions(),
                skipNaming: skipNaming,
                enqueueFile: enqueueFile,
                enqueueFiles: enqueueFilesRPC,
                enqueueReturningIDs: enqueueReturningIDs,
                jobStatus: jobStatus,
            )
        }
    #endif

    // MARK: - Derived properties

    /// Whether the auto-detect watch loop is active (not a manual recording).
    /// Delegates to `watching`; exposed here as a single-member accessor so the
    /// menu-bar body that reads `appState.isWatching` stays cheap to type-check.
    var isWatching: Bool {
        watching.isWatching
    }

    /// True when the caption-bar overlay should be visible: captions are
    /// available per the shared gate (master toggle on, and either the engine
    /// implements `transcribeSamples` or the English-streaming opt-in is on —
    /// the latter is engine-independent) AND an actual recording is in progress.
    var shouldShowLiveCaptions: Bool {
        LiveCaptionsGate.captionsAvailable(
            liveEnabled: settings.liveTranscriptionEnabled,
            englishStreaming: settings.liveCaptionsEnglishStreaming,
            engineSupportsLive: settings.transcriptionEngine.supportsLiveTranscription,
        ) && watching.watchLoop?.state == .recording
    }

    var currentBadge: BadgeKind {
        let loop = watching.watchLoop
        return BadgeKind.compute(
            watchLoopActive: loop?.isActive == true,
            watchLoopState: loop?.state ?? .idle,
            transcriberState: loop?.transcriberState ?? .idle,
            activeJobState: pipeline.queue.activeJobs.first?.state,
            updateAvailable: updateChecker.availableUpdate != nil,
            permissionProblem: permissions.health?.isHealthy == false,
        )
    }

    var currentStateLabel: String {
        if let loop = watching.watchLoop, loop.isActive {
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

    /// Whether the active loop is a manual recording (vs. auto-detect). Drives
    /// the menu-bar "Stop Recording" item; hoisted to a single-member accessor
    /// so the body reading it through `watching.watchLoop` stays cheap.
    var isManualRecording: Bool {
        watching.watchLoop?.isManualRecording == true
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
        guard let loop = watching.watchLoop, loop.isActive else { return nil }

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
}

// MARK: - SilentNotifier

/// No-op notifier for CLI targets and tests that don't need notifications.
struct SilentNotifier: AppNotifying {
    func notify(title _: String, body _: String) {}
}
