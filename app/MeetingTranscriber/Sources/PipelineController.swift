import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineController")

// MARK: - PipelineController

/// Owns the post-processing pipeline concern: the `PipelineQueue` instance, its
/// construction from the current settings + active engine, the per-job
/// notification callbacks, and the file-enqueue entry points.
///
/// Extracted from `AppState` as a concern-specific controller (see the AppState
/// god-class split). `AppState` keeps the engine instances + the active-engine
/// switch and supplies the active engine via `activate(engineProvider:)` (called
/// post stored-property init, where the `[weak self]` engine closure is valid) so
/// this controller never holds an `AppState` back-reference. `settings` +
/// `notifier` are shared references injected at construction.
///
/// `@Observable` because `queue` is read by the menu-bar UI + RPC snapshot: when
/// `rebuild()` swaps in a freshly-wired queue, the views observing `queue`
/// through `AppState.pipeline.queue` must re-read. Nested-`@Observable`
/// observation through `let pipeline` + this stored `var queue` is the same
/// pattern the other extracted controllers use.
@Observable
@MainActor
final class PipelineController {
    /// The active pipeline queue. Settable so tests can swap in a queue wired to
    /// an isolated `logDir` (byte-equivalent to the prior `AppState.pipelineQueue`
    /// var, which was likewise publicly settable). Production mutates it only via
    /// `rebuild()` / `ensureQueue()`.
    var queue: PipelineQueue

    private let settings: AppSettings
    private let notifier: any AppNotifying

    /// Durable finished-job record store, shared across queue rebuilds and read
    /// by `jobStatus(forID:)` for the automation API. Test-injectable.
    let terminalJobStore: TerminalJobStore

    /// Source of the currently-active engine. Set by `activate`; nil before then
    /// (so `makeQueue()` safely returns the current queue if called early — only
    /// reachable at process teardown, since `rebuild`/`ensureQueue` are driven by
    /// user actions while `AppState` is alive). Captures the owner weakly.
    private var engineProvider: (() -> (any TranscribingEngine)?)?

    init(settings: AppSettings, notifier: any AppNotifying, terminalJobStore: TerminalJobStore? = nil) {
        self.settings = settings
        self.notifier = notifier
        self.terminalJobStore = terminalJobStore
            ?? TerminalJobStore(path: AppPaths.ipcDir.appendingPathComponent("terminal_jobs.json"))
        self.queue = PipelineQueue()
    }

    /// Wire the active-engine source. Called once from `AppState.init` after its
    /// stored-property init.
    func activate(engineProvider: @escaping () -> (any TranscribingEngine)?) {
        self.engineProvider = engineProvider
    }

    // MARK: - Queue lifecycle

    /// Rebuild the queue against the current settings + active engine and
    /// re-install the job-state callbacks. Unconditional — the watch-start path
    /// always rebuilds so a fresh session picks up the latest settings/engine.
    func rebuild() {
        queue = makeQueue()
        configureCallbacks()
    }

    /// Rebuild only when the queue isn't already wired to an engine. The
    /// manual-recording + file-enqueue paths call this so an already-configured
    /// queue (e.g. one a test injected) isn't replaced.
    func ensureQueue() {
        guard queue.engine == nil else { return }
        rebuild()
    }

    /// One-stop wired `PipelineQueue`: active engine from the provider, the
    /// diarization/protocol factories, current settings, then load the persisted
    /// snapshot + recover orphaned recordings off-main + refresh known names.
    func makeQueue() -> PipelineQueue {
        guard let engine = engineProvider?() else { return queue }
        let q = PipelineQueue(
            engine: engine,
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
            stageTimingLog: StageTimingLog(),
            terminalJobStore: terminalJobStore,
        )
        q.loadSnapshot()
        // Fire-and-forget: dir scan + per-file attr probes run off-main so app
        // startup (and the first call to `enqueueFiles`) isn't blocked by a slow
        // filesystem. Recovered jobs appear in `queue.jobs` once the scan returns.
        Task {
            // Rescue recordings whose writer was killed mid-stream (#379), then
            // hand off to the orphan scan which enqueues the results. Detached
            // so the dir scans + per-file rewrites/re-mixes run off-main and
            // don't block startup (same reason the orphan scan offloads its own
            // filesystem work). Order matters:
            //   1. repair unfinalized WAV headers so a crashed mic track reads,
            //   2. re-mix crashed recordings (raw app .tmp + mic) into a _mix.wav,
            //   3. delete any temp the re-mix couldn't use.
            await Task.detached(priority: .utility) {
                let repaired = WavHeaderRepair.repairUnfinalized(in: AppPaths.recordingsDir)
                if repaired > 0 { logger.info("Repaired \(repaired) unfinalized recording(s) on launch") }
                let recovered = DualSourceRecorder.recoverCrashedRecordings()
                if recovered > 0 { logger.info("Recovered \(recovered) crashed recording(s) on launch") }
                DualSourceRecorder.cleanupTempFiles()
            }.value
            await q.recoverOrphanedRecordings()
        }
        q.refreshKnownSpeakerNames()
        return q
    }

    /// One-stop FluidDiarizer instantiation. Captures the current tuning fields
    /// from settings so both the global-mode factory and the per-job
    /// mode-override factory stay in sync. Tuning only affects `.offline` mode,
    /// but is harmless when passed to `.sortformer`.
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

    // `makeProtocolGenerator` + `configureCallbacks` are module-internal (not
    // `private`) to preserve the access level they had on `AppState` before this
    // extraction — they encode real behavior (provider selection, notification
    // routing) that is unit-tested directly, same altitude as the other wiring
    // methods above.
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
                    ?? URL(string: AppSettings.defaultOpenAIEndpoint)!,
                model: settings.openAIModel,
                language: settings.protocolLanguage,
                apiKey: settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey,
            )

        case .none:
            nil
        }
    }

    func configureCallbacks() {
        queue.onJobStateChange = { [notifier] job, _, newState in
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

    // MARK: - File enqueue

    /// Filters `urls` to files that currently exist on disk, enqueues them, and
    /// returns the count of files that existed. RPC-friendly entry point.
    ///
    /// NOTE: this is the count of *files that existed*, not jobs created — a
    /// paired `_app` + `_mic` import collapses two files into one job. The
    /// `/action/enqueueFiles` response contract is the file count, so this must
    /// not be derived from `enqueueExistingFilesReturningIDs(_:).count`.
    @discardableResult
    func enqueueExistingFiles(_ urls: [URL]) -> Int {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return 0 }
        enqueueFiles(existing)
        return existing.count
    }

    /// Like `enqueueExistingFiles` but returns the created job IDs so an
    /// automation client can poll each job's status. `[]` when no URL exists on
    /// disk. Distinct from the file count above: paired imports yield fewer IDs
    /// than files.
    @discardableResult
    func enqueueExistingFilesReturningIDs(_ urls: [URL], autoSkipNaming: Bool = false) -> [UUID] {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return [] }
        return enqueueFiles(existing, autoSkipNaming: autoSkipNaming)
    }

    @discardableResult
    func enqueueFiles(_ urls: [URL], autoSkipNaming: Bool = false) -> [UUID] {
        ensureQueue()

        let resolution = PairedRecordingResolver.resolve(urls: urls)
        var ids: [UUID] = []

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
                autoSkipNaming: autoSkipNaming,
            )
            ids.append(job.id)
            queue.enqueue(job)
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
                autoSkipNaming: autoSkipNaming,
            )
            ids.append(job.id)
            queue.enqueue(job)
        }

        return ids
    }

    // MARK: - Job status

    /// Current status of a job for the automation API: the live job if it's
    /// still in the queue, otherwise the persisted terminal record once the
    /// queue has reaped it, otherwise nil (unknown ID → the RPC layer 404s).
    func jobStatus(forID id: UUID) -> JobStatusDTO? {
        if let job = queue.jobs.first(where: { $0.id == id }) {
            return JobStatusDTO(job: job)
        }
        return terminalJobStore.lookup(jobID: id)
    }

    // MARK: - Speaker naming (automation API)

    /// Naming data for a job that is *actually* awaiting resolution — both in
    /// `.speakerNamingPending` state and with stashed data. Guarding on the
    /// state (not just the dict) makes confirm/skip idempotent: confirming
    /// transitions the job out of `.speakerNamingPending` synchronously, so a
    /// duplicate call (e.g. an automation retry) is rejected before it can
    /// double-record recognition or spawn a second re-apply.
    private func pendingNamingData(forID id: UUID) -> PipelineQueue.SpeakerNamingData? {
        guard queue.jobs.first(where: { $0.id == id })?.state == .speakerNamingPending else { return nil }
        return queue.speakerNamingDataByJob[id]
    }

    /// The speaker-naming choice awaiting resolution for a job, or nil when the
    /// job has no naming pending (unknown ID → the RPC layer 404s). Excludes
    /// embeddings.
    func namingStatus(forID id: UUID) -> NamingStatusDTO? {
        guard let data = pendingNamingData(forID: id) else { return nil }
        let speakers = data.mapping.keys.sorted().map { label in
            NamingStatusDTO.Speaker(
                label: label,
                suggested: data.mapping[label] ?? label,
                speakingSeconds: data.speakingTimes[label] ?? 0,
            )
        }
        return NamingStatusDTO(
            jobID: id.uuidString, meetingTitle: data.meetingTitle,
            speakers: speakers, participants: data.participants,
        )
    }

    /// Confirm speaker names for a pending job. Returns false when the job has no
    /// naming awaiting resolution (→ the RPC layer 404s); idempotent on retry.
    @discardableResult
    func confirmNaming(jobID: UUID, mapping: [String: String]) -> Bool {
        resolveNaming(jobID: jobID, result: .confirmed(mapping))
    }

    /// Skip speaker naming for a single pending job (accept the auto-names).
    /// Returns false when the job has no naming awaiting resolution.
    @discardableResult
    func skipNaming(jobID: UUID) -> Bool {
        resolveNaming(jobID: jobID, result: .skipped)
    }

    /// Shared guard + dispatch for confirm/skip: act only on a job actually
    /// awaiting naming, returning whether it did (false → 404).
    private func resolveNaming(jobID: UUID, result: PipelineQueue.SpeakerNamingResult) -> Bool {
        guard pendingNamingData(forID: jobID) != nil else { return false }
        queue.completeSpeakerNaming(jobID: jobID, result: result)
        return true
    }

    // MARK: - Blocking transcribe (one-call automation API)

    /// Enqueue a single file with `autoSkipNaming` so it completes headlessly
    /// (the queue accepts the auto-assigned speaker names instead of parking at
    /// `.speakerNamingPending`), then wait until the job reaches a terminal
    /// state. Returns `.noFile` when the path doesn't exist, `.timedOut` with
    /// the in-flight status once `maxWaitSeconds` elapses (the job keeps running
    /// and will still finish on its own), else `.completed` with the terminal
    /// status.
    func transcribeAndWait(
        path: URL,
        maxWaitSeconds: Double,
        pollInterval: Duration = .milliseconds(200),
    ) async -> BlockingTranscribeResult {
        guard let jobID = enqueueExistingFilesReturningIDs([path], autoSkipNaming: true).first
        else { return .noFile }
        let deadline = ContinuousClock.now.advanced(by: .seconds(maxWaitSeconds))
        while ContinuousClock.now < deadline {
            if let job = queue.jobs.first(where: { $0.id == jobID }) {
                if job.state == .done || job.state == .error { return .completed(JobStatusDTO(job: job)) }
            } else if let record = terminalJobStore.lookup(jobID: jobID) {
                return .completed(record) // already reaped from the live queue
            }
            try? await Task.sleep(for: pollInterval)
        }
        // Final read: a job that went terminal in the last sub-interval window
        // (or while we were enqueuing with maxWaitSeconds==0) is completed, not
        // timed out.
        let final = jobStatus(forID: jobID)
        if let final, final.state == .done || final.state == .error { return .completed(final) }
        return .timedOut(final)
    }
}

/// Outcome of a blocking `transcribeAndWait`. The RPC layer maps `noFile` → 400,
/// `completed` → 200, `timedOut` → 202.
enum BlockingTranscribeResult {
    case noFile
    case completed(JobStatusDTO)
    case timedOut(JobStatusDTO?)
}
