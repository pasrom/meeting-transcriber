// swiftlint:disable file_length
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// Raw diarization output for one run of the diarize loop. `combined` is the
/// result fed into speaker naming (the prefixed dual-track merge, the app-only
/// fallback, or the single-source result); `app`/`mic` are retained for the
/// dual-track assignment step. Internal top-level (not `PipelineQueue`-nested)
/// because it crosses the queue ↔ `SpeakerNamingSession` boundary in both
/// directions via `SpeakerNamingSessionDelegate`.
struct DiarizationRun {
    let app: DiarizationResult?
    let mic: DiarizationResult?
    let combined: DiarizationResult?
}

@MainActor
@Observable
// swiftlint:disable:next attributes type_body_length
class PipelineQueue {
    /// Internal setter (not `private(set)`) because the stage methods in
    /// PipelineQueue+Stages.swift mutate jobs in place
    /// (transcriptPath/protocolPath/namingSlug) across the file boundary.
    var jobs: [PipelineJob] = []
    private let logDir: URL

    /// File-backed skip list of already-processed recordings, consulted by
    /// `recoverOrphanedRecordings` so completed jobs aren't re-queued as
    /// orphans on the next launch.
    let processedLedger: ProcessedRecordingsLedger

    /// Append-only JSONL log of job state transitions (`pipeline_log.jsonl`).
    /// Self-ensures its own dir, so it doesn't share the queue's cached
    /// `logDirCreated` flag.
    let eventLog: PipelineEventLog

    // Dependencies for processing
    let engine: (any TranscribingEngine)?
    let diarizationFactory: (() -> any DiarizationProvider)?
    /// Optional mode-overriding factory used by `lateDiarization` when the
    /// user picks a different mode in the re-run UI. `nil` = mode override
    /// not supported, `lateDiarization` falls back to `diarizationFactory()`
    /// (current global setting). Production wires both via `AppState`.
    let diarizationFactoryWithMode: ((DiarizerMode) -> any DiarizationProvider)?
    let protocolGeneratorFactory: (() -> (any ProtocolGenerating)?)?
    let outputDir: URL?
    let diarizeEnabled: Bool
    let numSpeakers: Int
    let micLabel: String
    let speakerMatcherFactory: () -> SpeakerMatcher
    let vadConfig: VADConfig?
    /// nil disables JSONL logging. AppState injects a real instance for production;
    /// tests leave it nil unless they explicitly want to assert on the log.
    let recognitionStatsLog: RecognitionStatsLog?

    /// nil disables per-stage timing capture. AppState injects a real instance;
    /// tests leave it nil unless asserting on the log.
    let stageTimingLog: StageTimingLog?

    let completedJobLifetime: TimeInterval

    /// Durable store of finished-job records for the automation API readback.
    /// nil (default) disables it; production injects one, tests opt in.
    let terminalJobStore: TerminalJobStore?

    /// Cached FluidVAD instance — reused across jobs to avoid model reload.
    /// Internal (not private) because `preprocessWithVAD` in
    /// PipelineQueue+Stages.swift reads and writes it.
    var vad: FluidVAD?

    /// Elapsed seconds since the current pipeline stage started.
    private(set) var activeJobElapsed: TimeInterval = 0
    /// Internal setter (not `private(set)`) because `processNext` in
    /// PipelineQueue+Stages.swift clears this flag across the file boundary.
    var isProcessing = false

    /// Historical average wall-clock seconds per (stage, engine, diarizer-mode)
    /// config (last 30 days), used by the menu to show "live vs. typical".
    /// Keyed by full config so the menu compares a Sortformer run against
    /// Sortformer history, not a blended offline/Sortformer average. Refreshed
    /// from `stageTimingLog` at launch and after each stage; empty until the log
    /// has data. Read via `averageSeconds(forJobID:stage:)`.
    private(set) var stageAverageByConfig: [StageConfig: Double] = [:]

    /// When the current `.transcribing`/`.diarizing`/`.generatingProtocol` state
    /// was entered, per job — so `updateJobState` can record the state's duration
    /// on exit (keyed by job to stay correct if transitions ever interleave).
    private var stageStartByJob: [UUID: ContinuousClock.Instant] = [:]
    /// Audio length (seconds) each job processed, captured when transcription
    /// completes, so stage durations can be normalised into an RTF.
    /// Internal (not private) because `transcribe` in PipelineQueue+Stages.swift stamps it.
    var jobAudioSeconds: [UUID: Double] = [:]

    private var elapsedTimer: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    /// Internal (not private) because `processNext` in PipelineQueue+Stages.swift
    /// reads this to distinguish a cancellation from a real pipeline error.
    var cancelledJobIDs = Set<UUID>()

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

    // MARK: - Speaker Naming

    /// Owns the speaker-naming session (dialog, sidecars, recognition
    /// forensics, late re-run). Held strongly; the session holds this queue as
    /// a *weak* delegate, so there's no retain cycle. Exposed as a stored
    /// property so SwiftUI observation follows into the nested `@Observable`
    /// when the UI reads the forwarders below.
    let naming: SpeakerNamingSession

    /// RAM cache of naming data, owned by `naming`. Forwarded (get + set) so the
    /// direct-dict reads at `PipelineController` / `AppState+RPC` and the tests
    /// keep working AND keep observing the session's storage.
    var speakerNamingDataByJob: [UUID: SpeakerNamingData] {
        get { naming.speakerNamingDataByJob }
        set { naming.speakerNamingDataByJob = newValue }
    }

    /// Handler for speaker naming, owned by `naming`. Forwarded so tests can set
    /// it on the queue as before. When set, called instead of the default
    /// continuation-based popup.
    var speakerNamingHandler: ((SpeakerNamingData) async -> SpeakerNamingResult)? {
        get { naming.speakerNamingHandler }
        set { naming.speakerNamingHandler = newValue }
    }

    /// The currently displayed naming data (first pending item).
    var pendingSpeakerNaming: SpeakerNamingData? {
        guard let firstPendingJob = pendingSpeakerNamingJobs.first else { return nil }
        return speakerNamingDataByJob[firstPendingJob.id]
    }

    /// Filesystem slug for a job's persisted artefacts. Thin alias for
    /// `SpeakerNamingStore.slug` — kept so existing call sites (`processNext`,
    /// tests) don't have to reach into the store for a pure helper.
    static func namingSlug(title: String, jobID: UUID) -> String {
        SpeakerNamingStore.slug(title: title, jobID: jobID)
    }

    /// Returns naming data for a specific job ID, or the first pending job as fallback.
    func speakerNamingData(forJobID jobID: UUID?) -> SpeakerNamingData? {
        if let jobID, let data = speakerNamingDataByJob[jobID] { return data }
        return pendingSpeakerNaming
    }

    /// Diarizer mode used to produce the current `speakerNamingDataByJob`
    /// entry for the given job. `nil` for legacy jobs persisted before the
    /// field existed — callers fall back to the current global setting.
    func usedDiarizerMode(forJobID jobID: UUID) -> DiarizerMode? {
        jobs.first { $0.id == jobID }?.usedDiarizerMode
    }

    /// Jobs in speakerNamingPending state.
    var pendingSpeakerNamingJobs: [PipelineJob] {
        jobs.filter { $0.state == .speakerNamingPending }
    }

    /// Called by the UI (and the test handler) when the user confirms, skips, or
    /// re-runs speaker naming. Thin forwarder to the naming session, which
    /// always handles "late" completion — the pipeline never blocks on naming.
    func completeSpeakerNaming(jobID: UUID, result: SpeakerNamingResult) {
        naming.completeSpeakerNaming(jobID: jobID, result: result)
    }

    /// Called by the UI when the user confirms or skips speaker naming without a
    /// specific job in hand — resolves the first pending job (or any stashed
    /// naming data) and forwards to the session.
    func completeSpeakerNaming(result: SpeakerNamingResult) {
        if let jobID = pendingSpeakerNamingJobs.first?.id ?? naming.speakerNamingDataByJob.keys.first {
            naming.completeSpeakerNaming(jobID: jobID, result: result)
        }
    }

    /// Default factory for `speakerMatcherFactory`: a matcher that writes to a
    /// throwaway tmp path. Production callers (AppState) MUST inject an explicit
    /// factory pointing at the real `speakers.json`. This keeps the user's real
    /// DB safe from any test that constructs a PipelineQueue without injection.
    nonisolated static func throwawayMatcherFactory() -> () -> SpeakerMatcher {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineQueue-throwaway-\(UUID().uuidString).json")
        return { SpeakerMatcher(dbPath: path) }
    }

    /// Performs the actual disk write for the snapshot worker. Defaults to
    /// `PipelineSnapshot.save`; tests inject substitutes to count writes or
    /// simulate a stalled `replaceItemAt`.
    let snapshotWriter: @Sendable ([PipelineJob], URL) throws -> Void

    /// Simple init for skeleton tests and basic queue usage.
    init(
        logDir: URL? = nil,
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = PipelineQueue.throwawayMatcherFactory(),
        snapshotWriter: @escaping @Sendable ([PipelineJob], URL) throws -> Void = PipelineSnapshot.save,
        stageTimingLog: StageTimingLog? = nil,
        completedJobLifetime: TimeInterval = 60,
        terminalJobStore: TerminalJobStore? = nil,
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
        self.processedLedger = ProcessedRecordingsLedger(logDir: self.logDir)
        eventLog = PipelineEventLog(logDir: self.logDir)
        self.engine = nil
        self.diarizationFactory = nil
        self.diarizationFactoryWithMode = nil
        self.protocolGeneratorFactory = nil
        self.outputDir = nil
        self.diarizeEnabled = false
        self.numSpeakers = 0
        self.micLabel = "Me"
        self.speakerMatcherFactory = speakerMatcherFactory
        self.snapshotWriter = snapshotWriter
        self.vadConfig = nil
        self.recognitionStatsLog = nil
        self.stageTimingLog = stageTimingLog
        self.completedJobLifetime = completedJobLifetime
        self.terminalJobStore = terminalJobStore
        naming = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: nil),
            speakerMatcherFactory: speakerMatcherFactory,
        )
        naming.delegate = self
    }

    // MARK: - Known speaker names (issue #155)

    //
    // Cached snapshot of speaker names for the SpeakerNamingView's
    // "known voices" chip row. SwiftUI re-evaluates view bodies often
    // (every keystroke / hover / @State change in any sub-view), so
    // doing the work in the body — `speakerMatcherFactory().allSpeakerNames()`
    // — re-opens speakers.json and re-decodes every embedding per render.
    // With ~37 embeddings the main thread pinned at 100% CPU after
    // extended uptime (issue #155).
    //
    // The cache is refreshed on init and after every code path that
    // mutates the on-disk DB (recognition outcomes, rename, delete,
    // merge). UI reads `knownSpeakerNames` directly with zero I/O.

    private(set) var knownSpeakerNames: [String] = []

    func refreshKnownSpeakerNames() {
        let next = speakerMatcherFactory().allSpeakerNames()
        // Compare-before-assign: @Observable fires SwiftUI invalidations on
        // every set, even when the value is identical. The factory + decode
        // already happened at this point, but skipping the assign keeps
        // downstream view bodies from re-rendering unnecessarily.
        guard next != knownSpeakerNames else { return }
        knownSpeakerNames = next
    }

    /// Apply a speaker DB update via the matcher AND refresh the cached
    /// names in one step. Use instead of calling `matcher.updateDB(...)` +
    /// `refreshKnownSpeakerNames()` separately at internal pipeline sites.
    /// Internal (not private) because it is the `SpeakerNamingSessionDelegate`
    /// witness the session calls from `reapplySpeakerNames`; keeping the
    /// write+refresh pairing here preserves its atomicity (issue #155).
    func updateSpeakerDB(
        matcher: SpeakerMatcher,
        mapping: [String: String],
        embeddings: [String: [Float]],
        speakingTimes: [String: TimeInterval] = [:],
    ) {
        matcher.updateDB(
            mapping: mapping,
            embeddings: embeddings,
            speakingTimes: speakingTimes,
        )
        refreshKnownSpeakerNames()
    }

    /// Full init with all processing dependencies.
    init(
        engine: any TranscribingEngine,
        diarizationFactory: @escaping () -> any DiarizationProvider,
        diarizationFactoryWithMode: ((DiarizerMode) -> any DiarizationProvider)? = nil,
        protocolGeneratorFactory: @escaping () -> (any ProtocolGenerating)?,
        outputDir: URL,
        logDir: URL? = nil,
        diarizeEnabled: Bool = false,
        numSpeakers: Int = 0,
        micLabel: String = "Me",
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = PipelineQueue.throwawayMatcherFactory(),
        snapshotWriter: @escaping @Sendable ([PipelineJob], URL) throws -> Void = PipelineSnapshot.save,
        vadConfig: VADConfig? = nil,
        recognitionStatsLog: RecognitionStatsLog? = nil,
        stageTimingLog: StageTimingLog? = nil,
        completedJobLifetime: TimeInterval = 60,
        terminalJobStore: TerminalJobStore? = nil,
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
        self.processedLedger = ProcessedRecordingsLedger(logDir: self.logDir)
        eventLog = PipelineEventLog(logDir: self.logDir)
        self.engine = engine
        self.diarizationFactory = diarizationFactory
        self.diarizationFactoryWithMode = diarizationFactoryWithMode
        self.protocolGeneratorFactory = protocolGeneratorFactory
        self.outputDir = outputDir
        self.diarizeEnabled = diarizeEnabled
        self.numSpeakers = numSpeakers
        // "Remote" is the reserved routing tag for the app/remote track
        // (DiarizationProcess.remoteSpeakerLabel). If the user names the mic
        // speaker that too, mergeDualSourceSegments tags both tracks identically
        // and labelSegments' per-track filters each match every segment → app
        // audio is double-counted under both speakers. Fall back to the default
        // so the two routing tags can never collide. (This is the single source
        // of micLabel for both the tagging and the re-split, so sanitizing here
        // keeps them consistent.)
        self.micLabel = micLabel == DiarizationProcess.remoteSpeakerLabel ? "Me" : micLabel
        self.speakerMatcherFactory = speakerMatcherFactory
        self.snapshotWriter = snapshotWriter
        self.vadConfig = vadConfig
        self.recognitionStatsLog = recognitionStatsLog
        self.stageTimingLog = stageTimingLog
        self.completedJobLifetime = completedJobLifetime
        self.terminalJobStore = terminalJobStore
        naming = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: outputDir),
            speakerMatcherFactory: speakerMatcherFactory,
            diarizationFactory: diarizationFactory,
            diarizationFactoryWithMode: diarizationFactoryWithMode,
            protocolGeneratorFactory: protocolGeneratorFactory,
            outputDir: outputDir,
            recognitionStatsLog: recognitionStatsLog,
        )
        naming.delegate = self
        refreshStageAverages()
    }

    var activeJobs: [PipelineJob] {
        jobs.filter { [.transcribing, .diarizing, .generatingProtocol].contains($0.state) }
    }

    var pendingJobs: [PipelineJob] {
        jobs.filter { $0.state == .waiting }
    }

    var completedJobs: [PipelineJob] {
        jobs.filter { $0.state == .done }
    }

    func enqueue(_ job: PipelineJob) {
        jobs.append(job)
        eventLog.append(jobID: job.id, event: "enqueued", from: nil, to: job.state)
        saveSnapshot()
        logger.info("Enqueued job: \(job.meetingTitle, privacy: .private) (\(job.id))")
        triggerProcessing()
    }

    /// Test-only: insert a fully-formed job at any state, bypassing
    /// `enqueue()` and the processing trigger. Lets snapshot/observer tests
    /// exercise terminal states (`.done`, `.error`) without spinning real
    /// engines. Production code MUST go through `enqueue()`.
    func insertJobForTesting(_ job: PipelineJob) {
        jobs.append(job)
    }

    /// Wait for the queue to drain: any in-flight processing finishes and no
    /// jobs remain in `.waiting`. Used by tests that enqueue a job and need to
    /// observe a terminal state without racing against the spawned process task
    /// from `enqueue` → `triggerProcessing()`.
    func awaitProcessing() async {
        while isProcessing || !pendingJobs.isEmpty {
            if let task = processTask {
                await task.value
            } else {
                // processTask not yet assigned — yield so the spawning Task
                // can run.
                await Task.yield()
            }
        }
    }

    func removeJob(id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            processedLedger.markProcessed(mixPath: jobs[index].mixPath)
            jobs.remove(at: index)
        }
        stageStartByJob.removeValue(forKey: id)
        jobAudioSeconds.removeValue(forKey: id)
        saveSnapshot()
    }

    /// Cancel a job. Removes the job + cleans up sidecar files if naming was
    /// pending. Done/error jobs are not affected.
    func cancelJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let state = jobs[index].state
        let slug = jobs[index].namingSlug
        // cancelJob removes the job directly (not via removeJob) and skips the
        // normal terminal transition, so reap the stage-timing bookkeeping here
        // too — otherwise a job cancelled mid-stage leaks these entries.
        stageStartByJob.removeValue(forKey: id)
        jobAudioSeconds.removeValue(forKey: id)
        switch state {
        case .waiting:
            jobs.remove(at: index)
            saveSnapshot()

        case .transcribing, .diarizing, .generatingProtocol:
            cancelledJobIDs.insert(id)
            processTask?.cancel()
            naming.removeNamingData(jobID: id, slug: slug)
            jobs.remove(at: index)
            saveSnapshot()

        case .speakerNamingPending:
            // User cancelled while waiting for late-confirm — drop the sidecar
            // files and the in-memory state so it doesn't sit around.
            naming.removeNamingData(jobID: id, slug: slug)
            jobs.remove(at: index)
            saveSnapshot()

        case .done, .error:
            break
        }
    }

    func updateJobState(id: UUID, to newState: JobState, error: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let oldState = jobs[index].state
        // Skip a true no-op: same state AND no error to record. Without this,
        // re-entering the same state (e.g. the confirm path enters
        // `.generatingProtocol` twice) fires a redundant log line, snapshot
        // write, and `onJobStateChange` callback, and would latently schedule a
        // second `removeJob` cleanup Task on a re-`.done`. An error-only update
        // (same state, new message) must still apply and persist.
        guard oldState != newState || error != nil else { return }
        jobs[index].state = newState
        if let error { jobs[index].error = error }
        recordStageTransition(from: oldState, to: newState, jobID: id)
        eventLog.append(jobID: id, event: "state_change", from: oldState, to: newState)
        saveSnapshot()
        onJobStateChange?(jobs[index], oldState, newState)

        if newState == .done || newState == .error {
            processedLedger.markProcessed(mixPath: jobs[index].mixPath)
            recordTerminalJob(jobs[index])
        }
        if newState == .done {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.completedJobLifetime ?? 60))
                self?.removeJob(id: id)
            }
        }
    }

    /// Persist a durable terminal-state record so the automation API can read
    /// back a finished job's outcome even after `completedJobLifetime` removes
    /// it from the in-memory list. No-op when no store is wired.
    private func recordTerminalJob(_ job: PipelineJob) {
        terminalJobStore?.record(JobStatusDTO(job: job))
    }

    func addWarning(id: UUID, _ message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard !jobs[index].warnings.contains(message) else { return }
        jobs[index].warnings.append(message)
    }

    /// Reset the elapsed timer for a new pipeline stage.
    /// Internal (not private) because the stage methods in PipelineQueue+Stages.swift call it.
    func startElapsedTimer() {
        elapsedTimer?.cancel()
        activeJobElapsed = 0
        elapsedTimer = Task { [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let elapsed = ContinuousClock.now - start
                self?.activeJobElapsed = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
            }
        }
    }

    /// Stop the elapsed timer.
    /// Internal (not private) because the stage methods in PipelineQueue+Stages.swift call it.
    func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    // MARK: - Stage timing metrics

    /// On every state change: if we left a timed stage, log its wall-clock
    /// duration; if we entered one, stamp its start. Measuring per-state means
    /// the recorded duration matches exactly what the menu's elapsed timer shows
    /// and excludes the speaker-naming pause (see `StageKind(jobState:)`).
    private func recordStageTransition(from oldState: JobState, to newState: JobState, jobID: UUID) {
        // A same-state "transition" (e.g. the confirm path re-enters
        // .generatingProtocol while already .generatingProtocol) is not a stage
        // boundary; ignore it so it neither logs a partial event nor resets the start.
        guard oldState != newState else { return }
        if let leaving = StageKind(jobState: oldState), let start = stageStartByJob.removeValue(forKey: jobID) {
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            logStageTiming(stage: leaving, wallClock: seconds, jobID: jobID)
        }
        if StageKind(jobState: newState) != nil {
            stageStartByJob[jobID] = ContinuousClock.now
        }
    }

    /// Append one stage-timing event, then refresh the cached averages from the
    /// log so the menu reflects the new data point. Append and reload run in one
    /// Task so the reload is ordered strictly after the append (no race that
    /// could miss the just-logged event).
    private func logStageTiming(stage: StageKind, wallClock: Double, jobID: UUID) {
        guard let stageTimingLog else { return }
        // audioSeconds is 0 for stages with no known audio length (e.g. a late
        // re-diarization with no transcription this session); aggregate() then
        // excludes it from the RTF but still counts its wall-clock.
        let event = StageTimingEvent(
            ts: Date(), jobID: jobID, stage: stage,
            wallClockSeconds: wallClock, audioSeconds: jobAudioSeconds[jobID] ?? 0,
            engine: activeEngineTag,
            diarizerMode: usedDiarizerMode(forJobID: jobID)?.rawValue,
        )
        Task { [weak self] in
            await stageTimingLog.append([event])
            await self?.reloadStageAverages()
        }
    }

    /// Concrete transcription-engine type name, the comparability tag stamped on
    /// logged events; also used to resolve the active config for the menu.
    private var activeEngineTag: String? {
        engine.map { String(describing: type(of: $0)) }
    }

    /// The historical average for the config a job is running at a given stage —
    /// built the same way `logStageTiming` stamps events (engine + the job's
    /// diarizer mode), so the menu compares like-with-like. nil until that exact
    /// config has logged data.
    func averageSeconds(forJobID jobID: UUID, stage: StageKind) -> Double? {
        let config = StageConfig(
            stage: stage, engine: activeEngineTag,
            diarizerMode: usedDiarizerMode(forJobID: jobID)?.rawValue,
        )
        return stageAverageByConfig[config]
    }

    /// Reload recent timings and recompute the per-config average wall-clock.
    private func refreshStageAverages() {
        Task { [weak self] in await self?.reloadStageAverages() }
    }

    private func reloadStageAverages() async {
        guard let stageTimingLog else { return }
        let events = await stageTimingLog.loadRecent(within: 30 * 86400)
        // Key by full config (stage + engine + diarizer-mode) so the menu
        // resolves a like-with-like average per active job; see averageSeconds.
        stageAverageByConfig = StageTimingStats.aggregateByConfig(events: events)
            .mapValues(\.avgWallClockSeconds)
    }

    // MARK: - Processing

    /// Kick off processing if not already running and there are waiting jobs.
    /// Internal (not private) because `processNext` in PipelineQueue+Stages.swift
    /// re-triggers the queue after finishing a job.
    func triggerProcessing() {
        guard !isProcessing else { return }
        guard pendingJobs.first != nil else { return }
        isProcessing = true
        processTask = Task { [weak self] in
            await self?.processNext()
        }
    }

    // MARK: - Speaker Naming forwarders

    /// Auto-resolve pending naming items older than maxAge (default: 24h).
    /// Thin forwarder passing the queue's already-filtered
    /// `.speakerNamingPending` list to the session, which generates the protocol
    /// with auto-names, transitions them to .done, and deletes sidecar files.
    func cleanupStalePending(maxAge: TimeInterval = 86400) {
        naming.cleanupStalePending(pendingJobs: pendingSpeakerNamingJobs, maxAge: maxAge)
    }

    // MARK: - Snapshot Recovery

    /// Load pipeline queue from the JSON snapshot written by `saveSnapshot()`.
    /// Resets in-progress jobs to `.waiting`, discards `.done` jobs, and drops
    /// jobs whose `mixPath` no longer exists on disk.
    func loadSnapshot() {
        var loaded: [PipelineJob]
        do {
            guard let decoded = try PipelineSnapshot.load(from: logDir) else {
                logger.info("No pipeline snapshot to restore")
                return
            }
            loaded = decoded
        } catch {
            logger.error("Failed to load pipeline snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Reset active states back to waiting
        for i in loaded.indices {
            switch loaded[i].state {
            case .transcribing, .diarizing, .generatingProtocol:
                loaded[i].state = .waiting

            default:
                break
            }
        }

        // Discard done jobs
        loaded.removeAll { $0.state == .done }

        // Discard jobs whose audio file no longer exists, EXCEPT
        // .speakerNamingPending — those have their own slug-based
        // `_16k.wav` sidecar and don't need the original mix.wav.
        // Paired imports with nil mixPath: keep them — `appPath` is the
        // ground-truth source and it's checked at processNext time.
        loaded.removeAll { job in
            guard let mixPath = job.mixPath else { return false }
            return job.state != .speakerNamingPending
                && !FileManager.default.fileExists(atPath: mixPath.path)
        }

        guard !loaded.isEmpty else {
            logger.info("Snapshot loaded but no recoverable jobs")
            return
        }

        jobs = loaded

        // Rebuild the session's naming cache from disk for
        // .speakerNamingPending jobs.
        for job in jobs where job.state == .speakerNamingPending {
            if let slug = job.namingSlug, naming.restore(jobID: job.id, slug: slug) {
                continue
            }
            // Naming data lost — transition to done
            logger.warning("Naming data not found for job \(job.id), marking as done")
            if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[idx].state = .done
            }
        }

        saveSnapshot()
        cleanupStalePending()
        logger.info("Restored \(loaded.count) jobs from snapshot")
        triggerProcessing()
        // Auto-popup the naming dialog if any restored job is still
        // waiting for confirmation. Same notification as the in-pipeline
        // pop, so MeetingTranscriberApp brings the window forward.
        if !pendingSpeakerNamingJobs.isEmpty {
            NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
        }
    }

    // MARK: - Orphaned Recording Recovery

    /// Scan `recordingsDir` for `*_mix.wav` files not tracked by any loaded job.
    /// Creates recovery jobs for untracked recordings younger than `maxAge`.
    /// Skips files that were already successfully processed (tracked in processed_recordings.json).
    ///
    /// The directory scan + per-file `attributesOfItem` calls run on a
    /// detached task — startup callers don't block the UI on a potentially
    /// slow filesystem (e.g. iCloud-backed recordings dir). Mutations to
    /// `jobs` and the snapshot still happen on the main actor.
    func recoverOrphanedRecordings(
        recordingsDir: URL = AppPaths.recordingsDir,
        maxAge: TimeInterval = 86400,
    ) async {
        // One-time migration: seed processed list with existing recordings
        // Only for the default recordings directory (not test overrides)
        if recordingsDir == AppPaths.recordingsDir {
            await processedLedger.migrate(recordingsDir: recordingsDir)
        }

        let trackedPaths = Set(jobs.compactMap { $0.mixPath?.standardizedFileURL.path })
        let ledger = processedLedger

        // Off-main: directory scan + processed-list read + per-file
        // attributesOfItem probes + filtering all happen here.
        let candidates: [PairedRecordingResolver.Group] = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: recordingsDir,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            ) else { return [] }
            let processedPaths = ledger.load()
            let now = Date()
            return PairedRecordingResolver.resolve(urls: entries).paired.filter { group in
                // Groups without a real mix file (app+mic-only paired imports)
                // aren't recoverable from the dir scan alone.
                guard let mixURL = group.mix else { return false }
                let stdPath = mixURL.standardizedFileURL.path
                guard !trackedPaths.contains(stdPath) else { return false }
                guard !processedPaths.contains(stdPath) else { return false }
                let attrs = try? fm.attributesOfItem(atPath: mixURL.path)
                if let created = attrs?[.creationDate] as? Date,
                   now.timeIntervalSince(created) > maxAge {
                    return false
                }
                // Header-only WAVs are 44 bytes.
                if let size = attrs?[.size] as? Int, size <= 44 {
                    return false
                }
                return true
            }
        }.value

        guard !candidates.isEmpty else { return }

        for group in candidates {
            guard let mixURL = group.mix else { continue }
            let job = PipelineJob(
                meetingTitle: "Recovered Recording (\(group.stem))",
                appName: "Unknown",
                mixPath: mixURL,
                appPath: group.app,
                micPath: group.mic,
                micDelay: 0,
            )
            jobs.append(job)
            eventLog.append(jobID: job.id, event: "recovered", from: nil, to: .waiting)
        }
        saveSnapshot()
        logger.info("Recovered \(candidates.count) orphaned recording(s)")
        triggerProcessing()
    }

    // MARK: - Log Directory

    private var logDirCreated = false

    private func ensureLogDir() {
        guard !logDirCreated else { return }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logDirCreated = true
    }

    // Latest jobs array queued for the snapshot worker. Overwritten on
    // each `saveSnapshot()` so a burst of state changes collapses into a
    // single write of the final state instead of N sequential writes.
    // nil ≠ `[]`: nil means "nothing to write", `[]` would mean "write
    // the empty-jobs state" (valid when the last job was removed).
    // swiftlint:disable:next discouraged_optional_collection
    private var pendingSnapshotJobs: [PipelineJob]?
    private var snapshotWorker: Task<Void, Never>?

    /// Dedicated actor that owns the `replaceItemAt` syscall. Calling
    /// `await snapshotWriterActor.write(...)` from inside the detached task
    /// is a genuine cross-actor hop — guaranteed to leave the caller's
    /// executor (in particular MainActor) and run on the actor's own
    /// executor. This sidesteps Swift Concurrency's synchronous-start
    /// optimization that would otherwise keep `Task.detached`'s body on
    /// the caller's thread until the first real suspension. A stalled
    /// `renamex_np` (Spotlight indexer race on macOS 26) now blocks only
    /// this actor — never the UI, RPC, or watch loop.
    private let snapshotWriterActor = SnapshotWriterActor()

    /// Persist the current `jobs` array to disk. The write runs on a
    /// detached task and hops to `snapshotWriterActor` for the actual I/O —
    /// a stalled `replaceItemAt` (macOS 26 `mds_stores` rename deadlock)
    /// can't freeze the UI / RPC / watch loop. Rapid successive calls
    /// coalesce: only the last state is actually written.
    func saveSnapshot() {
        ensureLogDir()
        pendingSnapshotJobs = jobs
        guard snapshotWorker == nil else { return }
        let dir = logDir
        let writer = snapshotWriter
        let writeActor = snapshotWriterActor
        snapshotWorker = Task.detached(priority: .utility) { [weak self] in
            while let next = await self?.takeNextSnapshotBatch() {
                await writeActor.write(jobs: next, to: dir, using: writer)
            }
        }
    }

    // swiftlint:disable discouraged_optional_collection
    @MainActor
    private func takeNextSnapshotBatch() -> [PipelineJob]? {
        guard let next = pendingSnapshotJobs else {
            snapshotWorker = nil
            return nil
        }
        pendingSnapshotJobs = nil
        return next
    }

    // swiftlint:enable discouraged_optional_collection

    /// Wait for any queued snapshot writes to land on disk. Used by tests
    /// asserting on the file; production code may call this before quit if
    /// it needs the last snapshot durable, but the recovery path doesn't
    /// require it (orphans are re-scanned at next launch).
    func awaitSnapshotFlush() async {
        await snapshotWorker?.value
    }

    /// Test-only: true while a background snapshot worker is running.
    /// Lets tests assert the worker drains and clears itself.
    var isSnapshotWorkerActive: Bool {
        snapshotWorker != nil
    }
}

// MARK: - SpeakerNamingSessionDelegate

extension PipelineQueue: SpeakerNamingSessionDelegate {
    /// A value copy of the tracked job, addressed by id (never by a stale index).
    func job(withID id: UUID) -> PipelineJob? {
        jobs.first { $0.id == id }
    }

    /// Persist the per-job naming metadata on the (queue-owned) job. `nil` for
    /// either field means "leave unchanged". Mutates `jobs` in place (no
    /// snapshot write — matches the previous inline mutations).
    func setNamingMetadata(jobID: UUID, slug: String?, usedDiarizerMode: DiarizerMode?) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if let slug { jobs[idx].namingSlug = slug }
        if let usedDiarizerMode { jobs[idx].usedDiarizerMode = usedDiarizerMode }
    }

    /// Enter the diarizing stage for a late re-run: transition + start the
    /// menu's elapsed timer (in that order, matching the original inline flow).
    func namingStageDidStart(jobID: UUID) {
        updateJobState(id: jobID, to: .diarizing)
        startElapsedTimer()
    }

    /// Leave a timed naming stage.
    func namingStageDidEnd() {
        stopElapsedTimer()
    }
}
