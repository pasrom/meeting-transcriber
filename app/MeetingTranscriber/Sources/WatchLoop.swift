import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// Info about a manually started recording session.
struct ManualRecordingInfo {
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
    private var activeRecorder: RecordingProvider?
    private var manualRecordingTask: Task<Void, Never>?

    var isManualRecording: Bool {
        manualRecordingInfo != nil
    }

    // Dependencies
    let detector: MeetingDetecting
    let recorderFactory: @MainActor () -> RecordingProvider
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
    /// Dynamic accessor — destination directory for record-only output (WAVs +
    /// sidecar JSON). Defaults to the app's transient `recordingsDir`; in
    /// production wired to `<effectiveOutputDir>/recordings/` so users can
    /// point Syncthing or similar at a visible folder.
    let recordOnlyOutputDir: () -> URL
    /// Surface user-facing failures (e.g. sidecar write errors) that don't
    /// transition state to `.error`. Defaults to a silent no-op for tests.
    let notifier: any AppNotifying

    private var watchTask: Task<Void, Never>?

    /// Hook called when state changes (for UI updates, notifications, etc.)
    var onStateChange: ((State, State) -> Void)?

    init(
        detector: MeetingDetecting = WatchLoop.defaultDetector(),
        recorderFactory: @MainActor @escaping () -> RecordingProvider = { DualSourceRecorder() },
        pipelineQueue: PipelineQueue? = nil,
        pollInterval: TimeInterval = 3.0,
        endGracePeriod: TimeInterval = 15.0,
        maxDuration: TimeInterval = 14400,
        noMic: Bool = false,
        micDeviceUID: String? = nil,
        verboseDiagnostics: @escaping () -> Bool = { false },
        recordOnly: @escaping () -> Bool = { false },
        recordOnlyOutputDir: @escaping () -> URL = { AppPaths.recordingsDir },
        notifier: any AppNotifying = SilentNotifier(),
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
        self.recordOnlyOutputDir = recordOnlyOutputDir
        self.notifier = notifier
    }

    nonisolated static var defaultOutputDir: URL {
        AppPaths.downloadsProtocolsDir
    }

    nonisolated static func defaultDetector() -> MeetingDetecting {
        PowerAssertionDetector()
    }

    var isActive: Bool {
        state != .idle
    }

    // MARK: - Start / Stop

    func start() {
        guard watchTask == nil else { return }

        transition(to: .watching)
        detail = "Polling for meetings..."
        logger.info("Watch mode started (poll: \(self.pollInterval)s, grace: \(self.endGracePeriod)s)")

        watchTask = Task { [weak self] in
            guard let self else { return }
            await self.watchLoop()
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        currentMeeting = nil
        cleanupManualRecording()
        transition(to: .idle)
        detail = ""
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
        manualRecordingInfo = ManualRecordingInfo(pid: pid, appName: appName, title: title)
        transition(to: .recording)
        detail = "Recording: \(title)"

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

        do {
            let recording = try recorder.stop()
            enqueueRecording(title: info.title, appName: info.appName, recording: recording)
        } catch {
            logger.error("Failed to stop manual recording: \(error)")
            lastError = error.localizedDescription
        }

        activeRecorder = nil
        manualRecordingInfo = nil
        transition(to: .idle)
        detail = ""
    }

    private func monitorManualRecording(pid: pid_t) async {
        let startTime = Date()
        while !Task.isCancelled {
            // Check if process is still alive
            if kill(pid, 0) != 0 {
                logger.info("Monitored app (PID \(pid)) exited — stopping manual recording")
                stopManualRecording()
                return
            }

            // Enforce max duration
            if Date().timeIntervalSince(startTime) > maxDuration {
                logger.info("Max recording duration reached — stopping manual recording")
                stopManualRecording()
                return
            }

            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    private func cleanupManualRecording() {
        manualRecordingTask?.cancel()
        manualRecordingTask = nil
        activeRecorder = nil
        manualRecordingInfo = nil
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
                    lastError = error.localizedDescription
                    transition(to: .error)
                    detail = "Recording error: \(error.localizedDescription)"
                    try? await Task.sleep(for: .seconds(10))
                }

                detector.reset(appName: meeting.pattern.appName)

                if !Task.isCancelled {
                    transition(to: .watching)
                    detail = "Polling for meetings..."
                }
            }

            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    // MARK: - Meeting Handling

    func handleMeeting(_ meeting: DetectedMeeting) async throws {
        currentMeeting = meeting
        let title = Self.cleanTitle(meeting.windowTitle)

        // --- Recording ---
        transition(to: .recording)
        detail = "Recording: \(title)"

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
        let startTime = Date()

        while !Task.isCancelled {
            // Enforce max duration
            if Date().timeIntervalSince(startTime) > maxDuration {
                logger.info("Max recording duration reached (\(Int(self.maxDuration))s)")
                return
            }

            let active = detector.isMeetingActive(meeting)

            if active {
                if graceStart != nil {
                    graceStart = nil
                }
            } else {
                if graceStart == nil {
                    graceStart = Date()
                } else if let start = graceStart, Date().timeIntervalSince(start) >= endGracePeriod {
                    return
                }
            }

            try await Task.sleep(for: .seconds(pollInterval))
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
            let destDir = recordOnlyOutputDir()
            // The destination may be a user-chosen folder reached via a security-scoped
            // bookmark (App Store sandboxed build, or any custom Output Folder pick).
            // Without start/stopAccessingSecurityScopedResource the writes would silently
            // fail. Other writers (ProtocolGenerator, PipelineQueue) follow the same pattern.
            let accessing = destDir.startAccessingSecurityScopedResource()
            defer { if accessing { destDir.stopAccessingSecurityScopedResource() } }

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
            lastError = "Record-only output failed: \(error.localizedDescription)"
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

    private func transition(to newState: State) {
        let old = state
        state = newState
        if old != newState {
            onStateChange?(old, newState)
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
