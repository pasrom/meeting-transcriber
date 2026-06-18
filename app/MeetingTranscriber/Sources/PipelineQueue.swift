// swiftlint:disable file_length
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

@MainActor
@Observable
// swiftlint:disable:next attributes type_body_length
class PipelineQueue {
    private(set) var jobs: [PipelineJob] = []
    private let logDir: URL

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

    /// Disk persistence for speaker-naming sidecars (keyed by per-job slug).
    /// Pure I/O over `outputDir`; see `SpeakerNamingStore`.
    private let namingStore: SpeakerNamingStore

    /// Durable store of finished-job records for the automation API readback.
    /// nil (default) disables it; production injects one, tests opt in.
    let terminalJobStore: TerminalJobStore?

    /// Cached FluidVAD instance — reused across jobs to avoid model reload.
    private var vad: FluidVAD?

    /// Elapsed seconds since the current pipeline stage started.
    private(set) var activeJobElapsed: TimeInterval = 0
    private(set) var isProcessing = false

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
    private var jobAudioSeconds: [UUID: Double] = [:]

    private var elapsedTimer: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var cancelledJobIDs = Set<UUID>()

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

    // MARK: - Speaker Naming

    /// Data for the speaker naming popup.
    struct SpeakerNamingData: Codable {
        let jobID: UUID
        let meetingTitle: String
        let mapping: [String: String] // label → auto-matched name or label
        let speakingTimes: [String: TimeInterval]
        let embeddings: [String: [Float]]
        let audioPath: URL? // 16kHz mix for playback
        let segments: [Segment] // for extracting speaker snippets
        let participants: [String] // Teams participant names as suggestions
        let isDualSource: Bool
        /// Per-instance identity for SwiftUI `.onChange` change-detection.
        /// Late re-diarization can produce a `mapping`/`speakingTimes` set
        /// that compares byte-equal to the previous run (same speaker count,
        /// same matcher output) — without a fresh marker, the naming view's
        /// per-presentation reset never fires and consecutive Re-run clicks
        /// are silently swallowed by the `completedJobID` guard. Excluded
        /// from CodingKeys so disk reloads regenerate it.
        var revision: UUID = .init()

        private enum CodingKeys: String, CodingKey {
            case jobID, meetingTitle, mapping, speakingTimes, embeddings,
                 audioPath, segments, participants, isDualSource
        }

        struct Segment: Codable {
            let start: TimeInterval
            let end: TimeInterval
            let speaker: String
        }
    }

    /// Result from the speaker naming popup.
    enum SpeakerNamingResult {
        case confirmed([String: String]) // user confirmed with mapping
        case rerun(Int) // re-run diarization with N speakers (current mode)
        /// Re-run diarization with a different mode AND speaker count. New in
        /// the Mode↔Count-coupling follow-up: lets the user recover from a
        /// wrong-mode-at-recording-time (e.g. Sortformer's 4-speaker cap hit
        /// on a 6-speaker meeting) without leaving the naming dialog.
        case rerunWithMode(DiarizerMode, Int)
        case skipped // user skipped
    }

    /// RAM cache of naming data, rebuilt from disk on loadSnapshot().
    /// Internal setter allows test access via @testable import.
    var speakerNamingDataByJob: [UUID: SpeakerNamingData] = [:]

    /// Per-job snapshot of the auto-name suggestions shown in the dialog,
    /// kept until the user confirms/skips so `recordRecognition` can write
    /// the JSONL row. Cleared on completion. Not persisted across launches —
    /// if the user confirms in a fresh session, the recognition log row will
    /// have nil/empty `autoName` (acceptable; user data is the real signal).
    private var stashedSuggestedAtDialog: [UUID: [String: String]] = [:]
    private var stashedTopCandidates: [UUID: [String: [TopCandidate]]] = [:]

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

    /// Called by the UI when the user confirms, skips, or re-runs speaker naming.
    /// Always handles "late" completion — the pipeline never blocks on naming.
    func completeSpeakerNaming(jobID: UUID, result: SpeakerNamingResult) {
        guard let data = speakerNamingDataByJob[jobID] else { return }
        let slug = jobs.first { $0.id == jobID }?.namingSlug

        switch result {
        case let .confirmed(userMapping):
            recordRecognition(
                jobID: jobID, title: data.meetingTitle,
                userMapping: userMapping, fallback: data.mapping,
            )
            // Transition out of .speakerNamingPending synchronously so the
            // UI's close-when-empty check sees the change immediately. The
            // transcript rewrite + protocol generation happens async below.
            if let idx = jobs.firstIndex(where: { $0.id == jobID }),
               jobs[idx].state == .speakerNamingPending {
                updateJobState(id: jobID, to: .generatingProtocol)
            }
            Task { await reapplySpeakerNames(jobID: jobID, mapping: userMapping) }

        case let .rerun(count):
            Task { await lateDiarization(jobID: jobID, speakerCount: count) }

        case let .rerunWithMode(mode, count):
            Task { await lateDiarization(jobID: jobID, speakerCount: count, mode: mode) }

        case .skipped:
            recordRecognition(
                jobID: jobID, title: data.meetingTitle,
                userMapping: nil, fallback: data.mapping,
            )
            acceptAutoNames(jobID: jobID, slug: slug)
        }
    }

    /// Pull stashed forensics for a job and write the recognition-stats row.
    /// Falls back to the original SpeakerNamingData mapping when the stash is
    /// missing (e.g. the user confirmed in a fresh app session).
    private func recordRecognition(
        jobID: UUID, title: String,
        // swiftlint:disable:next discouraged_optional_collection
        userMapping: [String: String]?, fallback: [String: String],
    ) {
        recordRecognition(
            suggested: stashedSuggestedAtDialog[jobID] ?? fallback,
            userMapping: userMapping,
            topCandidates: stashedTopCandidates[jobID] ?? [:],
            jobID: jobID,
            title: title,
        )
    }

    /// Skipped or stale-cleanup path: the user accepted (implicitly or by
    /// timeout) the auto-names. Drops sidecar files synchronously, transitions
    /// to .done. If a protocol generator is configured AND the transcript file
    /// exists, fires off protocol generation in the background; the job
    /// transitions through .generatingProtocol → .done as that completes.
    private func acceptAutoNames(jobID: UUID, slug: String?) {
        // Probe the factory's actual output, not just its existence — the
        // closure is wired even when protocolProvider is `.none`, but
        // returns nil. Without this, the Task path below fizzles silently
        // (generateProtocol guards on factory()) and the job sits in
        // .speakerNamingPending forever.
        let canGenerateProtocol = (protocolGeneratorFactory?() != nil)
            && outputDir != nil
            && jobs.first { $0.id == jobID }?.transcriptPath != nil

        removeNamingData(jobID: jobID, slug: slug)

        if canGenerateProtocol {
            Task { await generateProtocolForExistingJob(jobID: jobID) }
        } else if let idx = jobs.firstIndex(where: { $0.id == jobID }),
                  jobs[idx].state == .speakerNamingPending {
            updateJobState(id: jobID, to: .done)
        }
    }

    private func generateProtocolForExistingJob(jobID: UUID) async {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
              let transcriptPath = jobs[jobIndex].transcriptPath,
              let outputDir,
              let transcript = try? String(contentsOf: transcriptPath, encoding: .utf8)
        else { return }
        await generateProtocol(
            jobID: jobID,
            transcript: transcript,
            title: jobs[jobIndex].meetingTitle,
            protocolsDir: outputDir.appendingPathComponent("protocols"),
        )
        if let idx = jobs.firstIndex(where: { $0.id == jobID }),
           jobs[idx].state == .generatingProtocol {
            updateJobState(id: jobID, to: .done)
        }
    }

    /// Called by the UI when the user confirms or skips speaker naming.
    func completeSpeakerNaming(result: SpeakerNamingResult) {
        if let jobID = pendingSpeakerNamingJobs.first?.id ?? speakerNamingDataByJob.keys.first {
            completeSpeakerNaming(jobID: jobID, result: result)
        }
    }

    /// Handler for speaker naming. When set, called instead of the default
    /// continuation-based popup. Receives naming data, returns result.
    /// Used by tests to auto-complete without UI interaction.
    var speakerNamingHandler: ((SpeakerNamingData) async -> SpeakerNamingResult)?

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
        self.namingStore = SpeakerNamingStore(outputDir: nil)
        self.terminalJobStore = terminalJobStore
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
    private func updateSpeakerDB(
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
        self.namingStore = SpeakerNamingStore(outputDir: outputDir)
        self.terminalJobStore = terminalJobStore
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
        appendLog(jobID: job.id, event: "enqueued", from: nil, to: job.state)
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
            markProcessed(mixPath: jobs[index].mixPath)
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
            removeNamingData(jobID: id, slug: slug)
            jobs.remove(at: index)
            saveSnapshot()

        case .speakerNamingPending:
            // User cancelled while waiting for late-confirm — drop the sidecar
            // files and the in-memory state so it doesn't sit around.
            removeNamingData(jobID: id, slug: slug)
            jobs.remove(at: index)
            saveSnapshot()

        case .done, .error:
            break
        }
    }

    func updateJobState(id: UUID, to newState: JobState, error: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let oldState = jobs[index].state
        jobs[index].state = newState
        if let error { jobs[index].error = error }
        recordStageTransition(from: oldState, to: newState, jobID: id)
        appendLog(jobID: id, event: "state_change", from: oldState, to: newState)
        saveSnapshot()
        onJobStateChange?(jobs[index], oldState, newState)

        if newState == .done || newState == .error {
            markProcessed(mixPath: jobs[index].mixPath)
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
    private func startElapsedTimer() {
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
    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    // MARK: - Stage timing metrics

    /// On every state change: if we left a timed stage, log its wall-clock
    /// duration; if we entered one, stamp its start. Measuring per-state means
    /// the recorded duration matches exactly what the menu's elapsed timer shows
    /// and excludes the speaker-naming pause (see `StageKind(jobState:)`).
    private func recordStageTransition(from oldState: JobState, to newState: JobState, jobID: UUID) {
        // A same-state "transition" (e.g. the inline speaker-count rerun re-enters
        // .diarizing while already .diarizing) is not a stage boundary — ignore it
        // so it neither logs a partial event nor resets the start.
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
    private func triggerProcessing() {
        guard !isProcessing else { return }
        guard pendingJobs.first != nil else { return }
        isProcessing = true
        processTask = Task { [weak self] in
            await self?.processNext()
        }
    }

    /// Process the first waiting job through the full pipeline:
    /// resample → transcribe → (diarize) → save transcript → generate protocol → save protocol.
    /// Immutable per-job inputs threaded through the pipeline stages.
    private struct JobContext {
        let jobID: UUID
        let shortID: String
        let title: String
        let mixPath: URL?
        let appPath: URL?
        let micPath: URL?
        let micDelay: TimeInterval
        let participants: [String]
        /// Persisted-file basename, computed once from title + jobID so the
        /// diarization and protocol stages agree on the same `\(slug)_16k.wav`.
        let slug: String
    }

    /// Output of the transcription stage, consumed by diarization + protocol save.
    private struct TranscriptionOutput {
        let transcript: String
        /// Segments cached for diarization reuse (avoids double transcription).
        let cachedSegments: [TimestampedSegment]? // swiftlint:disable:this discouraged_optional_collection
        let isDualSource: Bool
    }

    /// Raw diarization output for one run of the diarize loop. `combined` is the
    /// result fed into speaker naming (the prefixed dual-track merge, the
    /// app-only fallback, or the single-source result); `app`/`mic` are retained
    /// for the dual-track assignment step.
    private struct DiarizationRun {
        let app: DiarizationResult?
        let mic: DiarizationResult?
        let combined: DiarizationResult?
    }

    /// What the speaker-naming step decided for one diarization result: either
    /// re-run diarization with a new speaker count, or finalize with this
    /// speaker→name mapping.
    private enum SpeakerNamingOutcome {
        case rerun(Int)
        case finalized([String: String])
    }

    /// Per-run matcher outputs needed to update the speaker DB and write
    /// recognition forensics once the user confirms the naming dialog.
    private struct RecognitionContext {
        let matcher: SpeakerMatcher
        let embeddings: [String: [Float]]
        let speakingTimes: [String: TimeInterval]
        let suggested: [String: String]
        let topCandidates: [String: [TopCandidate]]
    }

    /// Typed errors thrown by the pipeline stages.
    enum PipelineError: LocalizedError {
        case missingMixPath
        case noMixAudioForDiarization

        var errorDescription: String? {
            switch self {
            case .missingMixPath: "Single-source job missing mixPath"
            case .noMixAudioForDiarization: "No mix audio available for diarization"
            }
        }
    }

    /// Thin orchestrator: take the next waiting job and run it through the
    /// pipeline — transcribe → diarize → generate protocol → done.
    func processNext() async {
        guard let index = jobs.firstIndex(where: { $0.state == .waiting }) else {
            isProcessing = false
            return
        }
        guard let engine, let outputDir else {
            logger.warning("Processing dependencies not configured — skipping")
            isProcessing = false
            return
        }
        let job = jobs[index]
        let ctx = JobContext(
            jobID: job.id,
            shortID: job.shortID,
            title: job.meetingTitle,
            mixPath: job.mixPath,
            appPath: job.appPath,
            micPath: job.micPath,
            micDelay: job.micDelay,
            participants: job.participants,
            slug: Self.namingSlug(title: job.meetingTitle, jobID: job.id),
        )

        do {
            // Temp directory for intermediate 16kHz files, cleaned up on any exit.
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pipeline_\(ctx.jobID.uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            let transcription = try await transcribe(ctx, engine: engine, workDir: workDir)

            guard !transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Compute input RMS only on the failure path — loading the whole
                // mix file is expensive (~MB-per-minute) and we only need it when
                // diagnosing why transcription produced nothing. Paired imports
                // without a real mix file report NaN (RMS unavailable).
                let inputRMS = ctx.mixPath.flatMap { AudioMixer.rmsDecibels(forFileAt: $0) } ?? .nan
                logger.warning(
                    "[\(ctx.shortID, privacy: .public)] transcription_empty inputRMSdBFS=\(inputRMS, privacy: .public). Likely silent input or ASR misconfiguration — check microphone level and engine settings.",
                )
                updateJobState(id: ctx.jobID, to: .error, error: "Empty transcript")
                isProcessing = false
                triggerProcessing()
                return
            }

            let finalTranscript = try await diarize(
                transcription, ctx: ctx, engine: engine,
                workDir: workDir, outputDir: outputDir,
            )

            try await generateAndSaveProtocol(
                finalTranscript: finalTranscript, transcription: transcription,
                ctx: ctx, workDir: workDir, outputDir: outputDir,
            )
        } catch is CancellationError {
            stopElapsedTimer()
            logger.info("Job \(ctx.jobID) cancelled")
            // Job already removed by cancelJob()
        } catch {
            stopElapsedTimer()
            if cancelledJobIDs.remove(ctx.jobID) != nil {
                logger.info("Job \(ctx.jobID) cancelled")
            } else {
                logger.error("Pipeline error for job \(ctx.jobID): \(error)")
                updateJobState(id: ctx.jobID, to: .error, error: error.localizedDescription)
            }
        }

        isProcessing = false
        triggerProcessing()
    }

    // MARK: - Pipeline stages

    /// Stage 1 — resample source audio to 16 kHz and transcribe. Dual-source
    /// tracks are transcribed separately and merged; single-source optionally
    /// runs VAD silence-trimming with timestamp remapping. Caches segments for
    /// diarization reuse.
    private func transcribe(
        _ ctx: JobContext, engine: any TranscribingEngine, workDir: URL,
    ) async throws -> TranscriptionOutput {
        updateJobState(id: ctx.jobID, to: .transcribing)
        startElapsedTimer()
        logger.info("[\(ctx.shortID, privacy: .public)] transcription_start title=\(ctx.title, privacy: .private)")

        let transcript: String
        // Segments cached for potential diarization reuse (avoids double transcription)
        var cachedSegments: [TimestampedSegment]? // swiftlint:disable:this discouraged_optional_collection
        let isDualSource = ctx.appPath != nil && ctx.micPath != nil
        if let appAudioPath = ctx.appPath, let micAudioPath = ctx.micPath {
            // Dual-source: resample both tracks to 16kHz concurrently
            let app16k = workDir.appendingPathComponent("app_16k.wav")
            let mic16k = workDir.appendingPathComponent("mic_16k.wav")
            async let appResample: Void = AudioMixer.resampleFile(from: appAudioPath, to: app16k)
            async let micResample: Void = AudioMixer.resampleFile(from: micAudioPath, to: mic16k)
            try await appResample
            try await micResample

            // Transcribe each track separately
            let appSegments = try await engine.transcribeSegments(audioPath: app16k)
            let micSegments = try await engine.transcribeSegments(audioPath: mic16k)

            // Merge dual-source segments
            let segments = DiarizationProcess.mergeDualSourceSegments(
                appSegments: appSegments,
                micSegments: micSegments,
                micDelay: ctx.micDelay,
                micLabel: micLabel,
            )
            cachedSegments = segments
            transcript = segments.map(\.formattedLine).joined(separator: "\n")
        } else {
            // Single-source: resample mix to 16kHz
            guard let mixPath = ctx.mixPath else {
                throw PipelineError.missingMixPath
            }
            let mix16k = workDir.appendingPathComponent("mix_16k.wav")
            try await AudioMixer.resampleFile(from: mixPath, to: mix16k)

            // Optional VAD preprocessing: trim silence before transcription
            var vadMap: VadSegmentMap?
            let transcriptionPath: URL
            if vadConfig != nil, let vadResult = try await preprocessWithVAD(audioPath: mix16k, workDir: workDir) {
                transcriptionPath = vadResult.trimmedPath
                vadMap = vadResult.map
            } else {
                transcriptionPath = mix16k
            }

            // Use transcribeSegments to cache results for diarization
            var segments = try await engine.transcribeSegments(audioPath: transcriptionPath)

            // Remap timestamps back to original timeline if VAD was used
            if let map = vadMap {
                segments = map.remapTimestamps(segments)
            }

            cachedSegments = segments
            transcript = segments.map(\.formattedLine).joined(separator: "\n")
        }

        stopElapsedTimer()

        let segCount = cachedSegments?.count ?? 0
        let totalSecs = cachedSegments?.last?.end ?? 0
        // Stash for stage-timing RTF: diarization/protocol of this job process
        // the same audio length.
        jobAudioSeconds[ctx.jobID] = totalSecs
        logger.info(
            "[\(ctx.shortID, privacy: .public)] transcription_complete segments=\(segCount, privacy: .public) duration=\(totalSecs, privacy: .public)s",
        )

        return TranscriptionOutput(transcript: transcript, cachedSegments: cachedSegments, isDualSource: isDualSource)
    }

    /// Stage 2 — optional speaker diarization. Returns the transcript with
    /// speaker labels applied, or the original transcript unchanged when
    /// diarization is disabled, unavailable, or fails. Drives the speaker-naming
    /// dialog loop and persists naming data + recognition forensics as side
    /// effects.
    private func diarize(
        _ transcription: TranscriptionOutput, ctx: JobContext,
        engine: any TranscribingEngine, workDir: URL, outputDir: URL,
    ) async throws -> String {
        var finalTranscript = transcription.transcript

        guard diarizeEnabled, let diarizationFactory else { return finalTranscript }
        // An engine without per-utterance timestamps (one that emits a single
        // whole-recording segment) can't be diarized — assignSpeakers would
        // collapse the entire meeting onto one speaker. Skip it and tell the
        // user why. Dual-source transcripts keep their per-track Remote/mic
        // labels (set in transcribe()); single-source stays unlabeled.
        guard engine.providesTimestamps else {
            logger.info("[\(ctx.shortID, privacy: .public)] diarization_skipped_no_timestamps")
            addWarning(
                id: ctx.jobID,
                "Speaker diarization needs per-utterance timestamps, which the selected transcription engine doesn't produce — speakers not labeled",
            )
            return finalTranscript
        }
        let diarizeProcess = diarizationFactory()
        guard diarizeProcess.isAvailable else {
            logger.info("[\(ctx.shortID, privacy: .public)] diarization_skipped")
            return finalTranscript
        }

        updateJobState(id: ctx.jobID, to: .diarizing)
        startElapsedTimer()
        let mix16k = try await ensureMixAudio(workDir: workDir, ctx: ctx)

        do {
            // Diarization + naming loop: re-runs if the user requests a
            // different speaker count.
            var speakerCount = numSpeakers > 0 ? numSpeakers : nil
            var autoNames: [String: String] = [:]
            var run = DiarizationRun(app: nil, mic: nil, combined: nil)

            namingLoop: while true {
                run = try await runDiarization(
                    diarizeProcess: diarizeProcess, useDualTrack: transcription.isDualSource,
                    speakerCount: speakerCount, workDir: workDir, ctx: ctx,
                )
                guard let currentDiarization = run.combined else { break }
                switch await resolveSpeakerNames(
                    diarization: currentDiarization, ctx: ctx,
                    diarizeProcess: diarizeProcess, isDualSource: transcription.isDualSource,
                    outputDir: outputDir,
                ) {
                case let .rerun(count):
                    speakerCount = count
                    continue namingLoop

                case let .finalized(names):
                    autoNames = names
                }
                break namingLoop
            }

            if let labeled = try await labeledTranscript(
                from: run, autoNames: autoNames, transcription: transcription,
                engine: engine, mix16k: mix16k,
            ) {
                finalTranscript = labeled
            }
            let segCount = run.combined?.segments.count ?? 0
            logger.info("[\(ctx.shortID, privacy: .public)] diarization_complete segments=\(segCount, privacy: .public)")
        } catch {
            logger.warning("[\(ctx.shortID, privacy: .public)] diarization_failed error=\(error.localizedDescription, privacy: .public)")
            addWarning(id: ctx.jobID, "Diarization failed — speakers not identified")
            // Continue with original transcript
        }

        return finalTranscript
    }

    /// Ensure a 16 kHz mix exists for diarization, returning its path. Single
    /// source already resampled it in the transcribe stage; paired imports
    /// without a real `_mix.wav` mix `app + mic` directly into the workdir cache
    /// (no persistent mix file written).
    private func ensureMixAudio(workDir: URL, ctx: JobContext) async throws -> URL {
        let mix16k = workDir.appendingPathComponent("mix_16k.wav")
        guard !FileManager.default.fileExists(atPath: mix16k.path) else { return mix16k }
        if let mixPath = ctx.mixPath, FileManager.default.fileExists(atPath: mixPath.path) {
            try await AudioMixer.resampleFile(from: mixPath, to: mix16k)
        } else if let appAudioPath = ctx.appPath, let micAudioPath = ctx.micPath {
            try AudioMixer.mix(
                appAudioPath: appAudioPath, micAudioPath: micAudioPath,
                outputPath: mix16k, micDelay: ctx.micDelay,
                sampleRate: AudioConstants.targetSampleRate,
            )
        } else {
            throw PipelineError.noMixAudioForDiarization
        }
        return mix16k
    }

    /// Run diarization for one loop iteration. Dual-track diarizes the app and
    /// mic tracks separately and tolerates a mic-track failure (silent track on
    /// hosts without a real input device) by falling back to app-only; the
    /// `combined` result is the prefixed merge (or the app-only result) fed into
    /// speaker naming. Single-source diarizes the mix directly.
    private func runDiarization(
        diarizeProcess: any DiarizationProvider, useDualTrack: Bool,
        speakerCount: Int?, workDir: URL, ctx: JobContext,
    ) async throws -> DiarizationRun {
        guard useDualTrack else {
            let diarization = try await diarizeProcess.run(
                audioPath: workDir.appendingPathComponent("mix_16k.wav"),
                numSpeakers: speakerCount, meetingTitle: ctx.title,
            )
            return DiarizationRun(app: nil, mic: nil, combined: diarization)
        }

        return try await runDualTrackDiarization(
            diarizeProcess: diarizeProcess,
            tracks: (
                app: workDir.appendingPathComponent("app_16k.wav"),
                mic: workDir.appendingPathComponent("mic_16k.wav"),
                micDelay: ctx.micDelay,
            ),
            speakerCount: speakerCount, title: ctx.title, jobID: ctx.jobID,
        )
    }

    /// Diarize the app + mic tracks separately, tolerating a mic-track failure
    /// (silent track on a host without a real input device). The app track is
    /// required; on mic failure the `combined` result is the *unprefixed* app
    /// diarization — so downstream naming keys stay consistent with the
    /// persisted app-only transcript — rather than the `R_`/`M_`-prefixed merge.
    /// Shared by the batch (`runDiarization`) and late re-run
    /// (`runLateDiarization`) paths so the mic-fail fallback can't diverge
    /// between them.
    private func runDualTrackDiarization(
        diarizeProcess: any DiarizationProvider,
        tracks: (app: URL, mic: URL, micDelay: TimeInterval),
        speakerCount: Int?, title: String, jobID: UUID,
    ) async throws -> DiarizationRun {
        let appDiarization = try await diarizeProcess.run(
            audioPath: tracks.app, numSpeakers: speakerCount, meetingTitle: title,
        )
        var micDiarization: DiarizationResult?
        do {
            let rawMic = try await diarizeProcess.run(
                audioPath: tracks.mic,
                numSpeakers: nil, // auto-detect local speakers
                meetingTitle: title,
            )
            // Shift the mic diarization onto the app/canonical timeline so it
            // aligns with the mic transcript segments, which
            // `mergeDualSourceSegments` already shifted by `+micDelay`.
            micDiarization = DiarizationProcess.shiftSegments(rawMic, by: tracks.micDelay)
        } catch {
            logger.warning(
                "[\(PipelineJob.shortID(for: jobID), privacy: .public)] mic_diarization_failed error=\(error.localizedDescription, privacy: .public) — falling back to app-only diarization",
            )
            addWarning(id: jobID, "Mic track diarization failed — speaker labels reflect remote audio only")
            micDiarization = nil
        }

        // App-only fallback (mic nil) feeds the speaker-naming loop with the
        // app diarization; the dual-track-app-only assignment branch then keeps
        // mic segments with their raw `micLabel` instead of force-matching them.
        let combined = micDiarization.map { mic in
            DiarizationProcess.mergeDualTrackDiarization(appDiarization: appDiarization, micDiarization: mic)
        } ?? appDiarization
        return DiarizationRun(app: appDiarization, mic: micDiarization, combined: combined)
    }

    /// Match a diarization result against the speaker DB, persist naming data +
    /// recognition forensics, and drive the speaker-naming dialog. Returns
    /// `.rerun` when the user asks for a different speaker count (the caller
    /// loops), or `.finalized` with the speaker→name mapping to apply.
    private func resolveSpeakerNames(
        diarization: DiarizationResult, ctx: JobContext,
        diarizeProcess: any DiarizationProvider, isDualSource: Bool, outputDir: URL,
    ) async -> SpeakerNamingOutcome {
        // No embeddings → no matching or dialog; keep the diarizer's own names.
        guard let embeddings = diarization.embeddings else { return .finalized(diarization.autoNames) }

        let matcher = speakerMatcherFactory()
        let verbose = matcher.matchVerbose(embeddings: embeddings)
        let matched = verbose.mapValues(\.assignedName)
        var autoNames = matched
        let topCandidates = verbose.mapValues(\.topCandidates)

        // Pre-match participants to remaining speakers.
        if !ctx.participants.isEmpty {
            autoNames = SpeakerMatcher.preMatchParticipants(
                mapping: autoNames,
                speakingTimes: diarization.speakingTimes,
                participants: ctx.participants,
            )
        }

        let suggestedAtDialog = autoNames
        let autoMatched = matched.count { $0.key != $0.value }
        logger.info("[recognition] \(matched.count) speakers, \(autoMatched) auto, \(matched.count - autoMatched) unknown")

        // Use persisted 16kHz path (survives workDir cleanup).
        let persistedAudioPath = outputDir.appendingPathComponent("recordings")
            .appendingPathComponent("\(ctx.slug)_16k.wav")
        let namingData = SpeakerNamingData(
            jobID: ctx.jobID,
            meetingTitle: ctx.title,
            mapping: autoNames,
            speakingTimes: diarization.speakingTimes,
            embeddings: embeddings,
            audioPath: persistedAudioPath,
            segments: diarization.segments.map { seg in
                SpeakerNamingData.Segment(start: seg.start, end: seg.end, speaker: seg.speaker)
            },
            participants: ctx.participants,
            isDualSource: isDualSource,
        )

        // Persist naming data and set slug early.
        saveNamingData(namingData, slug: ctx.slug)
        if let idx = jobs.firstIndex(where: { $0.id == ctx.jobID }) {
            jobs[idx].namingSlug = ctx.slug
            jobs[idx].usedDiarizerMode = diarizeProcess.mode
        }
        stopElapsedTimer()

        // Stash recognition forensics so the late-confirm path can write the
        // JSONL row when the user actually confirms (possibly later, via the
        // re-openable dialog).
        stashedSuggestedAtDialog[ctx.jobID] = suggestedAtDialog
        stashedTopCandidates[ctx.jobID] = topCandidates

        let recog = RecognitionContext(
            matcher: matcher, embeddings: embeddings, speakingTimes: diarization.speakingTimes,
            suggested: suggestedAtDialog, topCandidates: topCandidates,
        )
        return await applyNamingHandler(namingData: namingData, autoNames: autoNames, recog: recog, ctx: ctx)
    }

    /// Run the speaker-naming dialog (if a handler is installed) and turn its
    /// result into a `SpeakerNamingOutcome`. With no handler (production), stash
    /// the data and finalize on the auto-names without blocking; the re-openable
    /// dialog confirms later. `.confirmed` updates the speaker DB + records
    /// recognition forensics from `recog`.
    private func applyNamingHandler(
        namingData: SpeakerNamingData, autoNames: [String: String],
        recog: RecognitionContext, ctx: JobContext,
    ) async -> SpeakerNamingOutcome {
        if jobs.first(where: { $0.id == ctx.jobID })?.autoSkipNaming == true {
            // Headless blocking-transcribe: accept the auto-assigned names
            // inline (exactly like a `.skipped` dialog result) so the job
            // finishes on its own. Don't stash naming data — there is no
            // interactive client to resolve it, and parking would wedge the
            // job until the next launch's 24h stale-cleanup.
            return .finalized(autoNames)
        }
        guard let handler = speakerNamingHandler else {
            // Production: stash data, don't block the pipeline. The notification
            // is posted later — after the job transitions to
            // .speakerNamingPending — so the window's onAppear doesn't auto-close
            // it on a state mismatch.
            speakerNamingDataByJob[ctx.jobID] = namingData
            return .finalized(autoNames)
        }

        switch await handler(namingData) {
        case let .confirmed(userMapping):
            var confirmed = autoNames
            for (label, name) in userMapping where !name.isEmpty {
                confirmed[label] = name
            }
            updateSpeakerDB(
                matcher: recog.matcher, mapping: confirmed,
                embeddings: recog.embeddings, speakingTimes: recog.speakingTimes,
            )
            recordRecognition(
                suggested: recog.suggested, userMapping: userMapping,
                topCandidates: recog.topCandidates, jobID: ctx.jobID, title: ctx.title,
            )
            removeNamingData(jobID: ctx.jobID, slug: nil)
            return .finalized(confirmed)

        case let .rerun(count):
            return beginRerun(count: count, jobID: ctx.jobID)

        case let .rerunWithMode(_, count):
            // Mode override is only honoured by the production
            // completeSpeakerNaming -> lateDiarization path. The inline
            // test-handler loop can't swap providers mid-iteration without
            // rebuilding the factory; treat as a same-mode re-run.
            return beginRerun(count: count, jobID: ctx.jobID, logSuffix: " (mode override ignored in inline path)")

        case .skipped:
            return .finalized(autoNames)
        }
    }

    /// Transition back to diarizing for a speaker-count re-run and return the
    /// `.rerun` outcome the naming loop acts on.
    private func beginRerun(count: Int, jobID: UUID, logSuffix: String = "") -> SpeakerNamingOutcome {
        updateJobState(id: jobID, to: .diarizing)
        startElapsedTimer()
        logger.info("Re-running diarization with \(count) speakers\(logSuffix)")
        return .rerun(count)
    }

    /// Apply speaker names to the transcript for whichever topology the run
    /// produced (dual-track, mic-fail app-only fallback, or single-source),
    /// returning the labeled transcript — or `nil` when no diarization is
    /// available, leaving the caller's transcript unchanged. The three
    /// topologies share the merge + format tail, applied once here.
    private func labeledTranscript(
        from run: DiarizationRun, autoNames: [String: String],
        transcription: TranscriptionOutput, engine: any TranscribingEngine, mix16k: URL,
    ) async throws -> String? {
        let cachedSegments = transcription.cachedSegments
        let useDualTrack = transcription.isDualSource

        let topology: DiarizationProcess.LabelingTopology?
        if useDualTrack, let appDiar = run.app, let micDiar = run.mic, let cached = cachedSegments {
            topology = .dualTrack(cached: cached, micLabel: micLabel, app: appDiar, mic: micDiar)
        } else if useDualTrack, let appDiar = run.app, let cached = cachedSegments {
            // Mic diarization failed (silent track / no input device). Keep the
            // mic transcript with its raw `micLabel` — better than emitting
            // "speakers not identified" on a recording with good remote audio.
            topology = .dualTrackAppOnly(cached: cached, micLabel: micLabel, app: appDiar)
        } else if let currentDiarization = run.combined {
            // Single-source: standard assignment. cachedSegments is set by the
            // transcribe stage in practice; re-transcribe defensively.
            let segments = if let cached = cachedSegments {
                cached
            } else {
                try await engine.transcribeSegments(audioPath: mix16k)
            }
            topology = .single(segments: segments, diarization: currentDiarization)
        } else {
            return nil
        }
        guard let topology else { return nil }
        let labeled = DiarizationProcess.labelSegments(topology, autoNames: autoNames)
        return DiarizationProcess.mergeConsecutiveSpeakers(labeled).map(\.formattedLine).joined(separator: "\n")
    }

    /// Stage 3 — persist the transcript + audio, run protocol generation
    /// (unless speaker naming is still pending), and transition the job to its
    /// terminal state.
    private func generateAndSaveProtocol(
        finalTranscript: String, transcription: TranscriptionOutput,
        ctx: JobContext, workDir: URL, outputDir: URL,
    ) async throws {
        // --- Save Transcript & Audio (always) ---
        let protocolsDir = outputDir.appendingPathComponent("protocols")
        let txtPath = try ProtocolGenerator.saveTranscript(finalTranscript, title: ctx.title, dir: protocolsDir)
        logger.info("[\(ctx.shortID, privacy: .public)] transcript_saved file=\(txtPath.lastPathComponent, privacy: .private)")

        if let idx = jobs.firstIndex(where: { $0.id == ctx.jobID }) {
            jobs[idx].transcriptPath = txtPath
            jobs[idx].namingSlug = ctx.slug
        }

        let recordingsDir = outputDir.appendingPathComponent("recordings")
        Self.copyAudioToOutput(
            mixPath: ctx.mixPath, appPath: ctx.appPath, micPath: ctx.micPath,
            title: ctx.title, outputDir: recordingsDir,
        )

        // --- Persist 16kHz audio for re-diarization (move instead of copy to avoid double I/O) ---
        try? FileManager.default.moveItem(
            at: workDir.appendingPathComponent("mix_16k.wav"),
            to: recordingsDir.appendingPathComponent("\(ctx.slug)_16k.wav"),
        )

        if transcription.isDualSource {
            for (name, suffix) in [("app_16k.wav", "_app_16k.wav"), ("mic_16k.wav", "_mic_16k.wav")] {
                try? FileManager.default.moveItem(
                    at: workDir.appendingPathComponent(name),
                    to: recordingsDir.appendingPathComponent("\(ctx.slug)\(suffix)"),
                )
            }
        }

        // --- Persist transcript segments for late re-assignment ---
        if let cachedSegments = transcription.cachedSegments {
            let segPath = recordingsDir.appendingPathComponent("\(ctx.slug)_segments.json")
            if let data = try? JSONEncoder().encode(cachedSegments) {
                try? data.write(to: segPath, options: .atomic)
            }
        }

        // --- Protocol Generation (optional) ---
        // Skip when naming is pending — protocol will be generated on
        // confirm (with the right names) or on skip/stale-cleanup (with
        // the current auto-names). Saves an LLM call we'd otherwise
        // have to redo.
        if speakerNamingDataByJob[ctx.jobID] == nil {
            await generateProtocol(
                jobID: ctx.jobID, transcript: finalTranscript, title: ctx.title,
                protocolsDir: protocolsDir,
            )
        }

        stopElapsedTimer()
        if speakerNamingDataByJob[ctx.jobID] != nil {
            updateJobState(id: ctx.jobID, to: .speakerNamingPending)
            // Auto-pop the dialog now that the job is in the right state.
            // The window's onAppear guard reads pendingSpeakerNamingJobs,
            // which only includes .speakerNamingPending jobs, so the
            // notification has to come after the transition above.
            NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
        } else {
            updateJobState(id: ctx.jobID, to: .done)
        }
    }

    // MARK: - Protocol generation

    /// Run the LLM protocol generator over a transcript, save the .md file,
    /// stash its path on the job. No-op if no protocol generator is configured.
    /// Used by: main pipeline (if no naming pending), reapplySpeakerNames
    /// (after confirm), skipped/stale paths (with current auto-names).
    private func generateProtocol(
        jobID: UUID, transcript: String, title: String, protocolsDir: URL,
    ) async {
        guard let protocolGeneratorFactory, let generator = protocolGeneratorFactory() else {
            return
        }
        let shortID = PipelineJob.shortID(for: jobID)
        do {
            updateJobState(id: jobID, to: .generatingProtocol)
            startElapsedTimer()
            let diarized = transcript.range(
                of: #"\[\w[\w\s]*\]"#, options: .regularExpression,
            ) != nil
            let protocolMD = try await generator.generate(
                transcript: transcript, title: title, diarized: diarized,
            )
            let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + transcript
            let mdPath = try ProtocolGenerator.saveProtocol(
                fullMD, title: title, dir: protocolsDir,
            )
            logger.info("[\(shortID, privacy: .public)] protocol_saved file=\(mdPath.lastPathComponent, privacy: .private)")
            if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[idx].protocolPath = mdPath
            }
            stopElapsedTimer()
        } catch {
            logger.warning("[\(shortID, privacy: .public)] protocol_generation_failed error=\(error.localizedDescription, privacy: .public)")
            addWarning(id: jobID, "Protocol generation failed — transcript saved")
            stopElapsedTimer()
        }
    }

    // MARK: - Late re-apply speaker names

    /// Late-confirm path: read the saved transcript, replace generic speaker
    /// labels with user-provided names, update the matcher DB, regenerate the
    /// protocol with the correct names.
    private func reapplySpeakerNames(jobID: UUID, mapping: [String: String]) async {
        guard let namingData = speakerNamingDataByJob[jobID],
              let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        let slug = jobs[jobIndex].namingSlug

        // Update speaker matcher DB
        let matcher = speakerMatcherFactory()
        var fullMapping = namingData.mapping
        for (label, name) in mapping where !name.isEmpty {
            fullMapping[label] = name
        }
        updateSpeakerDB(
            matcher: matcher,
            mapping: fullMapping,
            embeddings: namingData.embeddings,
        )

        if let transcriptPath = jobs[jobIndex].transcriptPath {
            do {
                var transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
                // Format from `TimestampedSegment.formattedLine`: `[MM:SS] Speaker: text`.
                // Anchor the replace on `] ` + label + `:` so we hit the speaker
                // slot and not a substring inside the spoken text.
                for (label, name) in mapping where !name.isEmpty {
                    transcript = transcript.replacingOccurrences(of: "] \(label):", with: "] \(name):")
                    if let autoName = namingData.mapping[label], autoName != label, autoName != name {
                        transcript = transcript.replacingOccurrences(of: "] \(autoName):", with: "] \(name):")
                    }
                }
                try transcript.write(to: transcriptPath, atomically: true, encoding: .utf8)
                // Re-applying speaker names rewrites the transcript — keep it
                // owner-only (the original save in saveTranscript already is).
                try FileManager.default.restrictToOwner(transcriptPath)

                if let outputDir {
                    await generateProtocol(
                        jobID: jobID,
                        transcript: transcript,
                        title: jobs[jobIndex].meetingTitle,
                        protocolsDir: outputDir.appendingPathComponent("protocols"),
                    )
                }
            } catch {
                logger.error("Failed to re-apply speaker names: \(error)")
            }
        }

        removeNamingData(jobID: jobID, slug: slug)
        updateJobState(id: jobID, to: .done)
    }

    // MARK: - Late Re-diarization

    /// Re-run diarization from persisted 16kHz audio after pipeline completed.
    ///
    /// - Parameters:
    ///   - jobID: the job to re-diarize.
    ///   - speakerCount: target speaker count (ignored by Sortformer mode).
    ///   - mode: optional override for the diarizer mode. `nil` (default)
    ///     keeps the original behaviour — re-instantiate the diarizer with
    ///     the current global setting via `diarizationFactory()`. Non-nil
    ///     uses `diarizationFactoryWithMode` to instantiate a one-off
    ///     diarizer in the requested mode, so the user can recover from a
    ///     wrong-mode-at-recording-time without leaving the naming dialog.
    private func lateDiarization(
        jobID: UUID,
        speakerCount: Int,
        mode: DiarizerMode? = nil,
    ) async {
        guard let namingData = speakerNamingDataByJob[jobID],
              let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
              let diarizationFactory,
              let slug = jobs[jobIndex].namingSlug,
              let outputDir else {
            logger.warning("Cannot re-diarize: missing data or configuration")
            return
        }

        let recordingsDir = outputDir.appendingPathComponent("recordings")
        let diarizeProcess: any DiarizationProvider = {
            if let mode, let factory = diarizationFactoryWithMode {
                return factory(mode)
            }
            if let mode {
                logger.warning(
                    "Late re-diarize requested mode=\(mode.rawValue, privacy: .public) but no mode-aware factory wired; falling back to global setting",
                )
            }
            return diarizationFactory()
        }()
        guard diarizeProcess.isAvailable else {
            logger.warning("Diarization not available for late re-run")
            return
        }

        updateJobState(id: jobID, to: .diarizing)
        startElapsedTimer()

        do {
            let title = jobs[jobIndex].meetingTitle
            let diarization = try await runLateDiarization(
                diarizer: diarizeProcess,
                recording: (dir: recordingsDir, slug: slug, jobID: jobID, micDelay: jobs[jobIndex].micDelay),
                isDualSource: namingData.isDualSource,
                speakerCount: speakerCount, title: title,
            )
            stopElapsedTimer()

            guard let newNamingData = buildNamingData(
                jobID: jobID, title: title,
                diarization: diarization, prior: namingData,
            ) else {
                logger.warning("Late re-diarization produced no embeddings")
                updateJobState(id: jobID, to: .speakerNamingPending)
                return
            }

            speakerNamingDataByJob[jobID] = newNamingData
            saveNamingData(newNamingData, slug: slug)
            // Track which mode produced this fresh naming data so the next
            // dialog open initialises the mode picker correctly.
            jobs[jobIndex].usedDiarizerMode = diarizeProcess.mode

            updateJobState(id: jobID, to: .speakerNamingPending)
            NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)

            if let handler = speakerNamingHandler {
                let result = await handler(newNamingData)
                completeSpeakerNaming(jobID: jobID, result: result)
            }
        } catch {
            logger.error("Late re-diarization failed: \(error)")
            stopElapsedTimer()
            updateJobState(id: jobID, to: .speakerNamingPending)
        }
    }

    /// Re-diarize the persisted 16 kHz audio for a job. Dispatches between
    /// dual-source (separate app + mic tracks merged) and single-source
    /// (mix only). Pure I/O helper extracted from `lateDiarization` to
    /// keep its function body under the lint cap.
    private func runLateDiarization(
        diarizer: any DiarizationProvider,
        recording: (dir: URL, slug: String, jobID: UUID, micDelay: TimeInterval),
        isDualSource: Bool,
        speakerCount: Int,
        title: String,
    ) async throws -> DiarizationResult {
        let (recordingsDir, slug, jobID, micDelay) = recording
        if isDualSource {
            // Mirror the batch path's mic-fail fallback (via the shared helper):
            // a silent/failing mic track must degrade to the unprefixed app-only
            // diarization, not throw (a no-op re-run) or emit prefixed keys the
            // persisted app-only transcript can't match.
            let run = try await runDualTrackDiarization(
                diarizeProcess: diarizer,
                tracks: (
                    app: recordingsDir.appendingPathComponent("\(slug)_app_16k.wav"),
                    mic: recordingsDir.appendingPathComponent("\(slug)_mic_16k.wav"),
                    micDelay: micDelay,
                ),
                speakerCount: speakerCount, title: title, jobID: jobID,
            )
            // Dual-track always yields a combined result (the merge or the
            // app-only fallback); the optional is only the diarize-loop
            // placeholder's concern.
            guard let combined = run.combined else { throw DiarizationError.notAvailable }
            return combined
        }
        let mix16k = recordingsDir.appendingPathComponent("\(slug)_16k.wav")
        return try await diarizer.run(
            audioPath: mix16k, numSpeakers: speakerCount, meetingTitle: title,
        )
    }

    /// Build SpeakerNamingData from fresh diarization, reusing context from prior naming data.
    private func buildNamingData(
        jobID: UUID, title: String,
        diarization: DiarizationResult, prior: SpeakerNamingData,
    ) -> SpeakerNamingData? {
        guard let embeddings = diarization.embeddings else { return nil }

        let matcher = speakerMatcherFactory()
        var autoNames = matcher.match(embeddings: embeddings)
        if !prior.participants.isEmpty {
            autoNames = SpeakerMatcher.preMatchParticipants(
                mapping: autoNames,
                speakingTimes: diarization.speakingTimes,
                participants: prior.participants,
            )
        }

        return SpeakerNamingData(
            jobID: jobID, meetingTitle: title, mapping: autoNames,
            speakingTimes: diarization.speakingTimes, embeddings: embeddings,
            audioPath: prior.audioPath,
            segments: diarization.segments.map { seg in
                SpeakerNamingData.Segment(start: seg.start, end: seg.end, speaker: seg.speaker)
            },
            participants: prior.participants, isDualSource: prior.isDualSource,
        )
    }

    // MARK: - Speaker Naming Persistence

    /// Persist naming data via `namingStore`, surfacing a per-job warning on
    /// failure (the store stays I/O-only; the queue owns the job-state side
    /// effect). A silent failure would mean late-confirm won't work after a
    /// restart, so make it visible: log + warning on the job.
    private func saveNamingData(_ data: SpeakerNamingData, slug: String) {
        do {
            try namingStore.save(data, slug: slug)
        } catch {
            logger.error("Failed to save naming data: \(error.localizedDescription)")
            addWarning(id: data.jobID, "Late re-confirm unavailable — naming data could not be persisted")
        }
    }

    /// Remove all naming-related data for a job: RAM caches, disk JSON, and
    /// sidecar files. Also clears the recognition-stats stash dicts so they
    /// don't leak across rerun / stale-cleanup paths.
    private func removeNamingData(jobID: UUID, slug: String?) {
        speakerNamingDataByJob.removeValue(forKey: jobID)
        stashedSuggestedAtDialog.removeValue(forKey: jobID)
        stashedTopCandidates.removeValue(forKey: jobID)
        namingStore.deleteNamingJSON(slug: slug)
        namingStore.cleanupSidecarFiles(slug: slug)
    }

    /// Auto-resolve pending naming items older than maxAge (default: 24h).
    /// Generates the protocol with auto-names, transitions them to .done,
    /// deletes sidecar files.
    func cleanupStalePending(maxAge: TimeInterval = 86400) {
        let now = Date()
        for job in jobs where job.state == .speakerNamingPending {
            if now.timeIntervalSince(job.enqueuedAt) > maxAge {
                logger.info("Auto-resolving stale pending naming for \(job.meetingTitle, privacy: .private)")
                let jobID = job.id
                let slug = job.namingSlug
                acceptAutoNames(jobID: jobID, slug: slug)
            }
        }
    }

    // MARK: - VAD Preprocessing

    /// Run VAD on a 16kHz audio file. Returns trimmed audio path and segment map,
    /// or nil if no speech regions are detected.
    private func preprocessWithVAD(audioPath: URL, workDir: URL) async throws
        -> (trimmedPath: URL, map: VadSegmentMap)? {
        guard let vadConfig else { return nil }

        let vadInstance = vad ?? {
            let v = FluidVAD(threshold: vadConfig.threshold)
            vad = v
            return v
        }()

        let (samples, _) = try await AudioMixer.loadAudioAsFloat32(url: audioPath)
        let map = try await vadInstance.detectSpeech(samples: samples)

        guard !map.segments.isEmpty else {
            logger.info("VAD: no speech detected")
            return nil
        }

        let speechSamples = map.extractSpeechSamples(from: samples)
        guard !speechSamples.isEmpty else { return nil }

        let trimmedPath = workDir.appendingPathComponent("vad_trimmed.wav")
        try AudioMixer.saveWAV(samples: speechSamples, sampleRate: AudioConstants.targetSampleRate, url: trimmedPath)

        let origStr = String(format: "%.1f", map.originalDuration)
        let trimStr = String(format: "%.1f", map.trimmedDuration)
        logger.info("VAD trimmed: \(origStr)s → \(trimStr)s")

        return (trimmedPath, map)
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
            logger.error("Failed to load pipeline snapshot: \(error)")
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

        // Rebuild speaker naming cache from disk for .speakerNamingPending jobs
        for job in jobs where job.state == .speakerNamingPending {
            if let slug = job.namingSlug, let data = namingStore.load(slug: slug) {
                speakerNamingDataByJob[job.id] = data
            } else {
                // Naming data lost — transition to done
                logger.warning("Naming data not found for job \(job.id), marking as done")
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[idx].state = .done
                }
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

    // MARK: - Audio File Copy

    /// Copy recording audio files to the protocol output directory. Nil
    /// `mixPath` (paired imports without a `_mix.wav` source) → mix slot
    /// is skipped, no persistent mix is written.
    private static func copyAudioToOutput(
        mixPath: URL?, appPath: URL?, micPath: URL?,
        title: String, outputDir: URL,
    ) {
        // Each move below renames-in-place — if two of the three URLs point at
        // the same file, the first move destroys the source for the next one.
        // Loud failure in dev/CI > silent data destruction.
        if let mixStd = mixPath?.standardizedFileURL {
            precondition(
                appPath.map { mixStd != $0.standardizedFileURL } ?? true,
                "copyAudioToOutput: mixPath aliases appPath — would destroy source",
            )
            precondition(
                micPath.map { mixStd != $0.standardizedFileURL } ?? true,
                "copyAudioToOutput: mixPath aliases micPath — would destroy source",
            )
        }

        let accessing = outputDir.startAccessingSecurityScopedResource()
        defer { if accessing { outputDir.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let slug = ProtocolGenerator.filename(title: title, ext: "").dropLast() // remove trailing "."
        let audioPaths: [(URL, String)] = [
            mixPath.map { ($0, "\(slug)\(RecordingFileSuffix.mix)") },
            appPath.map { ($0, "\(slug)\(RecordingFileSuffix.app)") },
            micPath.map { ($0, "\(slug)\(RecordingFileSuffix.mic)") },
        ].compactMap(\.self)

        let outputDirStd = outputDir.standardizedFileURL
        for (src, name) in audioPaths {
            let dst = outputDir.appendingPathComponent(name)
            // Source already in the target dir → move would just rename in place
            // with a fresh `<today_timestamp>_<title>` prefix, which produces an
            // endless compounding-rename loop on every re-import (orphan recovery
            // re-picks the new name on next launch). The file is already at its
            // final home; keep it put.
            if src.deletingLastPathComponent().standardizedFileURL == outputDirStd {
                logger.info("Audio already in output dir, skipping rename: \(src.lastPathComponent, privacy: .private)")
                continue
            }
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: src, to: dst)
                logger.info("Audio moved: \(name, privacy: .private)")
            } catch {
                logger.warning("Failed to move audio \(name, privacy: .private): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Orphaned Recording Recovery

    /// One-time migration: if no processed_recordings.json exists yet, seed it with
    /// all existing `_mix.wav` files so they don't get recovered on first launch after update.
    ///
    /// Dir scan + JSON encode + atomic write run on a detached task. The
    /// guard + `ensureLogDir` stay on the main actor so the migration is a
    /// no-op (no detached task spawned) when the processed file already
    /// exists — which is the steady-state case.
    func migrateProcessedRecordings(recordingsDir: URL) async {
        guard !FileManager.default.fileExists(atPath: processedRecordingsPath.path) else { return }
        ensureLogDir()
        let processedRecordingsPath = self.processedRecordingsPath
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: recordingsDir, includingPropertiesForKeys: nil,
            ) else { return }
            var paths = Set<String>()
            for file in entries where file.lastPathComponent.hasSuffix(RecordingFileSuffix.mix) {
                paths.insert(file.standardizedFileURL.path)
            }
            guard !paths.isEmpty else { return }
            do {
                let data = try JSONEncoder().encode(Array(paths))
                try data.write(to: processedRecordingsPath, options: .atomic)
                logger.info("Migration: seeded \(paths.count) existing recordings as processed")
            } catch {
                logger.error("Migration failed: \(error)")
            }
        }.value
    }

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
            await migrateProcessedRecordings(recordingsDir: recordingsDir)
        }

        let trackedPaths = Set(jobs.compactMap { $0.mixPath?.standardizedFileURL.path })
        let processedRecordingsPath = self.processedRecordingsPath

        // Off-main: directory scan + processed-list read + per-file
        // attributesOfItem probes + filtering all happen here.
        let candidates: [PairedRecordingResolver.Group] = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: recordingsDir,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            ) else { return [] }
            let processedPaths: Set<String> = {
                guard let data = try? Data(contentsOf: processedRecordingsPath),
                      let paths = try? JSONDecoder().decode([String].self, from: data)
                else { return [] }
                return Set(paths)
            }()
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
            appendLog(jobID: job.id, event: "recovered", from: nil, to: .waiting)
        }
        saveSnapshot()
        logger.info("Recovered \(candidates.count) orphaned recording(s)")
        triggerProcessing()
    }

    // MARK: - Processed Recordings Tracking

    private var processedRecordingsPath: URL {
        logDir.appendingPathComponent("processed_recordings.json")
    }

    /// Load the set of mix paths that completed successfully.
    private func loadProcessedPaths() -> Set<String> {
        guard let data = try? Data(contentsOf: processedRecordingsPath),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths)
    }

    /// Record that a job's mix file was successfully processed. Nil mixPath
    /// (paired imports without a `_mix.wav` source) is a no-op — there's no
    /// path to track for orphan recovery.
    func markProcessed(mixPath: URL?) {
        guard let mixPath else { return }
        var paths = loadProcessedPaths()
        paths.insert(mixPath.standardizedFileURL.path)
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(Array(paths))
            try data.write(to: processedRecordingsPath, options: .atomic)
        } catch {
            logger.error("Failed to write processed recordings: \(error)")
        }
    }

    // MARK: - JSON Logging

    private static let isoFormatter = ISO8601DateFormatter()
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

    private func appendLog(jobID: UUID, event: String, from: JobState?, to: JobState) {
        let entry: [String: String] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "job_id": jobID.uuidString,
            "event": event,
            "from": from?.rawValue ?? "-",
            "to": to.rawValue,
        ]
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(entry)
            let logPath = logDir.appendingPathComponent("pipeline_log.jsonl")
            // swiftlint:disable:next force_unwrapping
            let line = String(data: data, encoding: .utf8)! + "\n"
            if FileManager.default.fileExists(atPath: logPath.path) {
                let handle = try FileHandle(forWritingTo: logPath)
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                // swiftlint:disable:next force_unwrapping
                handle.write(line.data(using: .utf8)!)
            } else {
                try line.write(to: logPath, atomically: true, encoding: .utf8)
                // First write creates the file — restrict it to owner-only so
                // the meeting log isn't world-readable. Subsequent appends go
                // through the FileHandle branch and inherit these permissions.
                try FileManager.default.restrictToOwner(logPath)
            }
        } catch {
            logger.error("Failed to append pipeline log: \(error)")
        }
    }

    /// Build recognition events and persist them off the pipeline path. Logs
    /// outcome counts immediately; JSONL append runs in a detached Task.
    private func recordRecognition(
        suggested: [String: String],
        // swiftlint:disable:next discouraged_optional_collection
        userMapping: [String: String]?,
        topCandidates: [String: [TopCandidate]],
        jobID: UUID,
        title: String,
    ) {
        let events = RecognitionStats.buildEvents(
            suggested: suggested, userMapping: userMapping,
            topCandidates: topCandidates,
            jobID: jobID, meetingTitle: title,
        )
        var counts: [RecognitionAction: Int] = [:]
        for e in events {
            counts[e.action, default: 0] += 1
        }
        let parts = RecognitionAction.allCases
            .map { "\($0.rawValue)=\(counts[$0] ?? 0)" }
            .joined(separator: " ")
        logger.info("[recognition] outcome \(parts, privacy: .public)")
        if let recognitionStatsLog {
            Task { await recognitionStatsLog.append(events) }
        }
    }
}
