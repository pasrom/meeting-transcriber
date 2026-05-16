import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// Info about a manually started recording session.
struct ManualRecordingInfo: Equatable {
    let pid: pid_t
    let appName: String
    let title: String
}

/// Native Swift watch loop that replaces the Python watcher.
///
/// Orchestrates: meeting detection → recording → enqueue to PipelineQueue.
@MainActor
@Observable
class WatchLoop {
    enum State: String {
        case idle
        case watching
        case recording
        case error
    }

    private(set) var state: State = .idle
    private(set) var currentMeeting: DetectedMeeting?
    private(set) var lastError: String?
    private(set) var detail: String = ""

    // Manual recording
    private(set) var manualRecordingInfo: ManualRecordingInfo?
    private var activeRecorder: (any RecordingProvider)?
    private var manualRecordingTask: Task<Void, Never>?

    var isManualRecording: Bool {
        manualRecordingInfo != nil
    }

    // Dependencies
    let detector: any MeetingDetecting
    let recorderFactory: @MainActor () -> any RecordingProvider
    var pipelineQueue: PipelineQueue?
    var permissionChecker: () async -> HealthCheckResult = { await PermissionHealthCheck.runLive() }

    // Settings
    let pollInterval: TimeInterval
    let endGracePeriod: TimeInterval
    let maxDuration: TimeInterval
    let noMic: Bool
    let micDeviceUID: String?
    /// Dynamic accessor — read at recording-start time so toggling the setting
    /// at runtime takes effect on the next recording without an app restart.
    let verboseDiagnostics: () -> Bool
    /// Dynamic accessor — when true, skip the post-processing pipeline and
    /// instead write a `<basename>_meta.json` sidecar next to the recording.
    let recordOnly: () -> Bool
    /// Dynamic accessor — destination for record-only output (WAVs + sidecar
    /// JSON). Returns a `(scope, writeDir)` pair so we can call
    /// `startAccessingSecurityScopedResource()` on the *bookmark-resolved
    /// parent* (the URL the user actually picked) while writing into a
    /// `recordings/` subfolder. Calling start-access on a child URL silently
    /// fails inside the App Store sandbox — see `RecordOnlyDestination`.
    let recordOnlyDestination: () -> RecordOnlyDestination
    /// Surface user-facing failures (e.g. sidecar write errors) that don't
    /// transition state to `.error`. Defaults to a silent no-op for tests.
    let notifier: any AppNotifying

    /// Wall-clock source. Defaults to `Date()`; tests inject a `TestClock`
    /// so timing-sensitive paths become deterministic instead of racing
    /// against `Task.sleep`'s actual jitter on loaded CI runners.
    let nowProvider: () -> Date
    /// Sleep primitive. Defaults to `Task.sleep`; tests inject the
    /// matching `TestClock.sleep` so virtual time advances synchronously.
    let sleepProvider: (TimeInterval) async throws -> Void
    /// Process-alive probe. Defaults to `kill(pid, 0) == 0`; tests inject
    /// a closure with a deterministic answer so the
    /// `monitorManualRecording` switch arms can be exercised without
    /// spawning a real subprocess.
    let pidAliveCheck: (pid_t) -> Bool

    private var watchTask: Task<Void, Never>?

    /// Hook called when state changes (for UI updates, notifications, etc.)
    var onStateChange: ((State, State) -> Void)?

    init(
        detector: any MeetingDetecting = WatchLoop.defaultDetector(),
        recorderFactory: @MainActor @escaping () -> any RecordingProvider = { DualSourceRecorder() },
        pipelineQueue: PipelineQueue? = nil,
        pollInterval: TimeInterval = 3.0,
        endGracePeriod: TimeInterval = 15.0,
        maxDuration: TimeInterval = 14400,
        noMic: Bool = false,
        micDeviceUID: String? = nil,
        verboseDiagnostics: @escaping () -> Bool = { false },
        recordOnly: @escaping () -> Bool = { false },
        recordOnlyDestination: @escaping () -> RecordOnlyDestination = {
            .unscoped(AppPaths.recordingsDir)
        },
        notifier: any AppNotifying = SilentNotifier(),
        nowProvider: @escaping () -> Date = Date.init,
        sleepProvider: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        },
        pidAliveCheck: @escaping (pid_t) -> Bool = { kill($0, 0) == 0 },
    ) {
        self.detector = detector
        self.recorderFactory = recorderFactory
        self.pipelineQueue = pipelineQueue
        self.pollInterval = pollInterval
        self.endGracePeriod = endGracePeriod
        self.maxDuration = maxDuration
        self.noMic = noMic
        self.micDeviceUID = micDeviceUID
        self.verboseDiagnostics = verboseDiagnostics
        self.recordOnly = recordOnly
        self.recordOnlyDestination = recordOnlyDestination
        self.notifier = notifier
        self.nowProvider = nowProvider
        self.sleepProvider = sleepProvider
        self.pidAliveCheck = pidAliveCheck
    }

    nonisolated static var defaultOutputDir: URL {
        AppPaths.downloadsProtocolsDir
    }

    nonisolated static func defaultDetector() -> any MeetingDetecting {
        PowerAssertionDetector()
    }

    var isActive: Bool {
        state != .idle
    }

    /// Value-type view of the five observable fields. Useful for tests,
    /// `AppState+RPC` snapshots, and as the input/output shape for the
    /// upcoming pure-function reducer slice.
    var snapshot: WatchLoopState {
        WatchLoopState(
            phase: state,
            currentMeeting: currentMeeting,
            lastError: lastError,
            detail: detail,
            manualRecordingInfo: manualRecordingInfo,
        )
    }

    // MARK: - Start / Stop

    func start() {
        guard watchTask == nil else { return }

        update { next in
            next.phase = .watching
            next.detail = "Polling for meetings..."
        }
        logger.info("Watch mode started (poll: \(self.pollInterval)s, grace: \(self.endGracePeriod)s)")

        watchTask = Task { [weak self] in
            guard let self else { return }
            await self.watchLoop()
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        cleanupManualRecording()
        update { next in
            next.phase = .idle
            next.currentMeeting = nil
            next.detail = ""
        }
        logger.info("Watch mode stopped")
    }

    // MARK: - Manual Recording

    func startManualRecording(pid: pid_t, appName: String, title: String) async throws {
        guard state != .recording else {
            logger.warning("Cannot start manual recording — already recording")
            return
        }

        let health = await permissionChecker()
        if !health.isHealthy {
            throw RecorderError.permissionDenied(health.notificationBody)
        }

        // Stop auto-watch if active
        watchTask?.cancel()
        watchTask = nil

        let recorder = recorderFactory()
        try recorder.start(
            appPID: pid, noMic: noMic, micDeviceUID: micDeviceUID,
            debugLogging: verboseDiagnostics(),
        )

        activeRecorder = recorder
        update { next in
            next.phase = .recording
            next.manualRecordingInfo = ManualRecordingInfo(pid: pid, appName: appName, title: title)
            next.detail = "Recording: \(title)"
        }

        manualRecordingTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorManualRecording(pid: pid)
        }

        logger.info("Manual recording started for \(appName) (PID \(pid)): \(title)")
    }

    func stopManualRecording() {
        guard let recorder = activeRecorder, let info = manualRecordingInfo else { return }

        manualRecordingTask?.cancel()
        manualRecordingTask = nil

        var failureMessage: String?
        do {
            let recording = try recorder.stop()
            enqueueRecording(title: info.title, appName: info.appName, recording: recording)
        } catch {
            logger.error("Failed to stop manual recording: \(error)")
            failureMessage = error.localizedDescription
        }

        activeRecorder = nil
        update { next in
            next.phase = .idle
            next.manualRecordingInfo = nil
            next.detail = ""
            if let failureMessage { next.lastError = failureMessage }
        }
    }

    private func monitorManualRecording(pid: pid_t) async {
        let startTime = nowProvider()
        while !Task.isCancelled {
            let decision = ManualRecordingMonitorPolicy.step(
                pidAlive: pidAliveCheck(pid),
                elapsed: nowProvider().timeIntervalSince(startTime),
                maxDuration: maxDuration,
            )
            switch decision {
            case .continuePolling:
                break

            case .stopPidExited:
                logger.info("Monitored app (PID \(pid)) exited — stopping manual recording")
                stopManualRecording()
                return

            case .stopMaxDurationExceeded:
                logger.info("Max recording duration reached — stopping manual recording")
                stopManualRecording()
                return
            }
            try? await sleepProvider(pollInterval)
        }
    }

    private func cleanupManualRecording() {
        manualRecordingTask?.cancel()
        manualRecordingTask = nil
        activeRecorder = nil
        update { next in next.manualRecordingInfo = nil }
    }

    // MARK: - Watch Loop

    private func watchLoop() async {
        while !Task.isCancelled {
            if let meeting = detector.checkOnce() {
                do {
                    try await handleMeeting(meeting)
                } catch {
                    if error is CancellationError { return }
                    let msg = "Recording error: \(error)"
                    logger.error("\(msg)")
                    update { next in
                        next.phase = .error
                        next.lastError = error.localizedDescription
                        next.detail = "Recording error: \(error.localizedDescription)"
                    }
                    try? await sleepProvider(10)
                }

                detector.reset(appName: meeting.pattern.appName)

                if !Task.isCancelled {
                    update { next in
                        next.phase = .watching
                        next.detail = "Polling for meetings..."
                    }
                }
            }

            try? await sleepProvider(pollInterval)
        }
    }

    // MARK: - Meeting Handling

    func handleMeeting(_ meeting: DetectedMeeting) async throws {
        let title = Self.cleanTitle(meeting.windowTitle)

        // --- Recording ---
        update { next in
            next.phase = .recording
            next.currentMeeting = meeting
            next.detail = "Recording: \(title)"
        }

        let recorder = recorderFactory()
        try recorder.start(
            appPID: meeting.windowPID,
            noMic: noMic,
            micDeviceUID: micDeviceUID,
            debugLogging: verboseDiagnostics(),
        )

        // Read participants (Teams)
        var participants: [String] = []
        if meeting.pattern.appName == "Microsoft Teams",
           let names = ParticipantReader.readParticipants(pid: meeting.windowPID),
           !names.isEmpty {
            logger.info("Detected \(names.count) participants")
            participants = names
        }

        // Wait for meeting to end
        try await waitForMeetingEnd(meeting)

        // Stop recording
        let recording = try recorder.stop()

        // --- Enqueue for background processing ---
        enqueueRecording(
            title: title,
            appName: meeting.pattern.appName,
            recording: recording,
            participants: participants,
        )
    }

    // MARK: - Meeting End Detection

    func waitForMeetingEnd(_ meeting: DetectedMeeting) async throws {
        var graceStart: Date?
        let startTime = nowProvider()
        let config = WatchLoopEndConfig(
            maxDuration: maxDuration,
            endGracePeriod: endGracePeriod,
        )

        while !Task.isCancelled {
            let decision = WatchLoopEndPolicy.step(
                config: config,
                now: nowProvider(),
                startTime: startTime,
                graceStart: graceStart,
                meetingActive: detector.isMeetingActive(meeting),
            )
            switch decision {
            case .stopMaxDurationExceeded:
                logger.info("Max recording duration reached (\(Int(self.maxDuration))s)")
                return

            case .stopGraceExpired:
                return

            case let .continuePolling(newGraceStart):
                graceStart = newGraceStart
            }
            try await sleepProvider(pollInterval)
        }
    }

    // MARK: - Helpers

    private func enqueueRecording(
        title: String,
        appName: String,
        recording: RecordingResult,
        participants: [String] = [],
    ) {
        if recordOnly() {
            writeRecordOnlySidecar(
                title: title,
                appName: appName,
                recording: recording,
                participants: participants,
            )
            return
        }

        let job = PipelineJob(
            meetingTitle: title,
            appName: appName,
            mixPath: recording.mixPath,
            appPath: recording.appPath,
            micPath: recording.micPath,
            micDelay: recording.micDelay,
            participants: participants,
        )
        pipelineQueue?.enqueue(job)
        logger.info("Enqueued pipeline job for: \(title)")
    }

    /// Convert a `ProcessInfo.systemUptime`-based timestamp captured at recording
    /// start into a wall-clock `Date` by anchoring against "now" (also systemUptime).
    private func wallClockDate(forUptime uptime: TimeInterval, now: Date = Date()) -> Date {
        let elapsed = ProcessInfo.processInfo.systemUptime - uptime
        return now.addingTimeInterval(-elapsed)
    }

    private func writeRecordOnlySidecar(
        title: String,
        appName: String,
        recording: RecordingResult,
        participants: [String],
    ) {
        let stoppedAt = Date()
        let startedAt = wallClockDate(forUptime: recording.recordingStart, now: stoppedAt)

        let mixName = recording.mixPath.lastPathComponent
        let mixSuffix = DualSourceRecorder.mixFilenameSuffix
        let basename: String = if mixName.hasSuffix(mixSuffix) {
            String(mixName.dropLast(mixSuffix.count))
        } else {
            recording.mixPath.deletingPathExtension().lastPathComponent
        }

        do {
            let destination = recordOnlyDestination()
            // start/stopAccessingSecurityScopedResource MUST be called on the
            // URL that resolved from the bookmark (App Store sandboxed build,
            // or any custom Output Folder pick) — calling it on a child path
            // silently fails. We then write into the `recordings/` subfolder
            // beneath that scope.
            let accessing = destination.scope.startAccessingSecurityScopedResource()
            defer { if accessing { destination.scope.stopAccessingSecurityScopedResource() } }

            let destDir = destination.writeDir
            try FileManager.default.createDirectory(
                at: destDir, withIntermediateDirectories: true,
            )
            let movedMix = try Self.move(recording.mixPath, into: destDir)
            let movedApp = try recording.appPath.map { try Self.move($0, into: destDir) }
            let movedMic = try recording.micPath.map { try Self.move($0, into: destDir) }

            let sidecar = RecordingSidecar(
                title: title,
                appName: appName,
                startedAt: startedAt,
                stoppedAt: stoppedAt,
                participants: participants,
                micDelaySeconds: recording.micDelay,
                mixFilename: movedMix.lastPathComponent,
                appFilename: movedApp?.lastPathComponent,
                micFilename: movedMic?.lastPathComponent,
            )
            try sidecar.write(toDirectory: destDir, basename: basename)
            logger.info("Record-only: wrote sidecar + WAVs to \(destDir.path) for \(title)")
        } catch {
            logger.error("Record-only: \(error.localizedDescription)")
            update { next in
                next.lastError = "Record-only output failed: \(error.localizedDescription)"
            }
            // Record-only skips state transitions, so `lastError` alone is
            // never surfaced. Notify directly so the user learns about the
            // silent data-loss for downstream pipelines.
            notifier.notify(
                title: "Record-only output failed",
                body: error.localizedDescription,
            )
        }
    }

    /// Move a file into `destDir`, returning its new URL. If a file with the
    /// same name already exists at the destination it is overwritten.
    private static func move(_ source: URL, into destDir: URL) throws -> URL {
        let dest = destDir.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: source, to: dest)
        return dest
    }

    /// Single funnel through which every observable-field mutation flows.
    /// Build the next snapshot, hand it to `apply` to commit only the
    /// fields that actually changed, and let `apply` fire `onStateChange`
    /// on a phase transition. Co-located mutations stay coherent
    /// (a phase-change-plus-detail-update is one funnel call, not two
    /// separate property writes that consumers could observe mid-flight).
    private func update(_ transform: (inout WatchLoopState) -> Void) {
        var next = snapshot
        transform(&next)
        apply(next)
    }

    /// Commit a new snapshot field-wise. Each `if old != new { old = new }`
    /// guard avoids gratuitous `@Observable` invalidations for fields the
    /// transform left alone; emit `onStateChange` if the phase moved.
    private func apply(_ next: WatchLoopState) {
        let oldPhase = state
        if state != next.phase { state = next.phase }
        if currentMeeting != next.currentMeeting { currentMeeting = next.currentMeeting }
        if lastError != next.lastError { lastError = next.lastError }
        if detail != next.detail { detail = next.detail }
        if manualRecordingInfo != next.manualRecordingInfo {
            manualRecordingInfo = next.manualRecordingInfo
        }
        if oldPhase != next.phase {
            onStateChange?(oldPhase, next.phase)
        }
    }

    /// Strip app suffixes from meeting titles for cleaner display.
    static func cleanTitle(_ title: String) -> String {
        let suffixes = [" | Microsoft Teams", " - Zoom", " - Webex"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }

    /// Map WatchLoop state to TranscriberState for compatibility with existing UI.
    var transcriberState: TranscriberState {
        switch state {
        case .idle: .idle
        case .watching: .watching
        case .recording: .recording
        case .error: .error
        }
    }
}

/// Pair of URLs used by `WatchLoop` when persisting record-only output: the
/// `scope` URL is what `startAccessingSecurityScopedResource()` is called on
/// (the bookmark-resolved parent the user actually picked), and `writeDir` is
/// the sub-path under that scope where the WAV + sidecar files land.
///
/// The split exists because Apple's security-scoped-bookmark API only grants
/// access on the URL that resolved from the bookmark — calling start-access
/// on a *child* path silently fails inside the App Store sandbox while
/// appearing to work in the unsandboxed Homebrew build. The factory methods
/// below make the two cases (real bookmark vs. transient app dir) explicit
/// at every call site.
struct RecordOnlyDestination: Equatable {
    let scope: URL
    let writeDir: URL

    /// Production path: `parent` is the user-picked Output Folder (potentially
    /// resolved from a security-scoped bookmark) and the WAVs land under
    /// `parent/recordings/` so a Syncthing or rsync pair has a stable subtree.
    static func production(parent: URL) -> Self {
        Self(
            scope: parent,
            writeDir: parent.appendingPathComponent("recordings", isDirectory: true),
        )
    }

    /// Test/default path: no security scope to manage — `scope == writeDir`,
    /// so start-access is a harmless no-op and the writer hits `url` directly.
    static func unscoped(_ url: URL) -> Self {
        Self(scope: url, writeDir: url)
    }
}
