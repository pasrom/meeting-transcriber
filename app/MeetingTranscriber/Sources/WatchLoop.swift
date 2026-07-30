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
    /// Exposed for read-only access — AppState's per-channel level monitor polls
    /// `appLevelDBFS` / `micLevelDBFS` here at ~10 Hz to drive the asymmetric-silence
    /// indicator. Setter stays private so the recording lifecycle flows through
    /// this class only.
    private(set) var activeRecorder: (any RecordingProvider)?
    private var manualRecordingTask: Task<Void, Never>?

    var isManualRecording: Bool {
        manualRecordingInfo != nil
    }

    // Dependencies
    let detector: any MeetingDetecting
    let recorderFactory: @MainActor () async -> any RecordingProvider
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

    /// Suppresses re-prompting after a browser-meeting decline (issue #503).
    /// Internal so the consent gate can live in `WatchLoop+Consent.swift`.
    var consentPolicy: BrowserConsentPolicy

    /// The app whose consent prompt is currently parked, nil when no question
    /// is open. The answer is awaited in `consentTask` rather than inline, so
    /// this is what keeps a second prompt from going out on every poll while
    /// the first one waits. Internal (not `private(set)`) because
    /// `WatchLoop+Consent.swift` owns the transitions.
    var pendingConsentApp: String?

    /// A meeting the user approved, waiting for the loop to pick it up.
    /// Recordings start in the loop and nowhere else, so an answer arriving
    /// out of band parks here instead of starting one from the consent task.
    var approvedConsentMeeting: DetectedMeeting?

    /// The task awaiting the parked answer. Held so `stop()` can let go of it.
    var consentTask: Task<Void, Never>?

    /// Forget the open question. Not a decline: `WatchLoop+Consent` decides
    /// what an answer (or the lack of one) means.
    func clearConsentState() {
        pendingConsentApp = nil
        approvedConsentMeeting = nil
        consentTask = nil
    }

    private var watchTask: Task<Void, Never>?

    /// Hook called when state changes (for UI updates, notifications, etc.)
    var onStateChange: ((State, State) -> Void)?

    init(
        detector: any MeetingDetecting = WatchLoop.defaultDetector(),
        recorderFactory: @MainActor @escaping () async -> any RecordingProvider = { DualSourceRecorder() },
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
        consentPolicy: BrowserConsentPolicy = BrowserConsentPolicy(),
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
        self.consentPolicy = consentPolicy
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
        // Answer a parked prompt before the state goes idle: a question that
        // outlives the watching it was asked on behalf of would sit in
        // Notification Center offering to record with watching switched off.
        declineParkedConsent()
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
        // Same reason as in `stop()`: with the poll loop gone there is nothing
        // left to act on an answer, so the question must not stay open.
        declineParkedConsent()

        let recorder = await recorderFactory()
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

        logger.info("Manual recording started for \(appName) (PID \(pid)): \(title, privacy: .private)")
    }

    func stopManualRecording() {
        guard let recorder = activeRecorder, let info = manualRecordingInfo else { return }

        manualRecordingTask?.cancel()
        manualRecordingTask = nil

        var failureMessage: String?
        do {
            let recording = try recorder.stop()
            enqueueRecording(
                title: info.title, appName: info.appName, recording: recording, trigger: .manual,
            )
        } catch {
            logger.error("Failed to stop manual recording: \(error.localizedDescription, privacy: .public)")
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
            // A prompt answered since the last poll comes first: the answer
            // arrives out of band, but recordings only ever start here.
            // Re-checked because the answer may have landed while another
            // meeting was recording, which blocks this loop for its duration —
            // by now the approved call can be long over.
            if let approved = takeApprovedConsentMeeting(), detector.isMeetingActive(approved) {
                if await runMeeting(approved) { return }
            } else if let meeting = detector.checkOnce() {
                // Browser meetings (issue #503) ask before recording; native
                // meetings skip this (flag false). See WatchLoop+Consent.swift.
                // Asking does NOT block this loop — that is the whole point:
                // an unanswered prompt used to stop `checkOnce()` from running
                // for a full minute, so a Teams or Zoom call starting in that
                // window went unrecorded.
                if requestConsentIfNeeded(for: meeting) {
                    try? await sleepProvider(pollInterval)
                    continue
                }
                if await runMeeting(meeting) { return }
            }

            try? await sleepProvider(pollInterval)
        }
    }

    /// Record one meeting to completion and return to watching. True means the
    /// loop was cancelled mid-recording and must exit.
    private func runMeeting(_ meeting: DetectedMeeting) async -> Bool {
        do {
            try await handleMeeting(meeting)
        } catch {
            if error is CancellationError { return true }
            let msg = "Recording error: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
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
        return false
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

        let recorder = await recorderFactory()
        try recorder.start(
            appPID: meeting.windowPID,
            noMic: noMic,
            micDeviceUID: micDeviceUID,
            debugLogging: verboseDiagnostics(),
        )
        activeRecorder = recorder
        defer { activeRecorder = nil }

        // Read participants (Teams)
        var participants: [String] = []
        if meeting.pattern.appName == "Microsoft Teams",
           let names = ParticipantReader.readParticipants(pid: meeting.windowPID),
           !names.isEmpty {
            logger.info("Detected \(names.count) participants")
            participants = names
        }

        // Wait for meeting to end. If the watch task is cancelled mid-recording
        // — the user clicked Stop Watching, or started a manual recording, both
        // of which call `stop()` → `watchTask.cancel()` — treat it like a
        // natural meeting end: fall through and finalize the recording rather
        // than letting `CancellationError` discard it. The original bug lost
        // the entire recording here (no WAV finalization, no PipelineJob, no
        // naming dialog) because the cancellation propagated past `stop()` and
        // `enqueueRecording()`. `recorder.stop()` + `enqueueRecording()` below
        // are synchronous, so they still run to completion on the cancelled task.
        do {
            try await waitForMeetingEnd(meeting)
        } catch is CancellationError {
            logger.info("Watch cancelled mid-recording — finalizing in-flight recording")
        }

        // Stop recording
        let recording = try recorder.stop()

        // --- Enqueue for background processing ---
        enqueueRecording(
            title: title,
            appName: meeting.pattern.appName,
            recording: recording,
            trigger: .auto,
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
        trigger: RecordingSidecar.Trigger,
        participants: [String] = [],
    ) {
        if recordOnly() {
            do {
                try writeRecordOnlySidecar(
                    title: title,
                    appName: appName,
                    recording: recording,
                    trigger: trigger,
                    participants: participants,
                )
            } catch {
                // Error left redacted: a sidecar/WAV write error embeds the
                // meeting-title-derived basename in its description.
                logger.error("Record-only: \(error.localizedDescription)")
                update { next in
                    next.lastError = "Record-only output failed: \(error.localizedDescription)"
                }
                // Record-only performs no state transition, so `lastError` is
                // never surfaced on its own. The notification is the only way
                // the user learns their fleet pipeline lost this recording.
                notifier.notify(
                    title: "Record-only output failed",
                    body: error.localizedDescription,
                )
            }
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
            meetingStartTime: recording.recordingStartDate,
        )
        pipelineQueue?.enqueue(job)
        logger.info("Enqueued pipeline job for: \(title, privacy: .private)")
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
