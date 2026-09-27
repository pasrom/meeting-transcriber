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

    /// Decides the folder a new queue writes into, and tells the user when it is
    /// not the one they chose (see `OutputDirectoryResolver`). Built from the
    /// settings and notifier this controller already holds. Not private:
    /// `WatchingController`'s record-only path writes into the same folder
    /// without a queue and goes through this same instance, so an
    /// unavailability episode is reported once, whichever seam meets it first.
    let outputDirectory: OutputDirectoryResolver

    /// Durable finished-job record store, shared across queue rebuilds and read
    /// by `jobStatus(forID:)` for the automation API. Test-injectable.
    let terminalJobStore: TerminalJobStore

    /// Where the queues this controller builds keep their data and how they
    /// reach the output folder, beyond the settings: the logs and snapshot, the
    /// staging folder they may relocate from, how the output folder's security
    /// scope is opened, the recovery of that staging folder a new queue runs,
    /// and how the output folder is resolved. Production uses `.production`,
    /// the app's own data directories; a test passes temp folders so a queue it
    /// builds never reads or writes the installed app's data.
    struct QueueEnvironment {
        var logDir: URL?
        var stagingDir: URL
        var securityScope: SecurityScopeAccess = .live
        /// Rescues crashed recordings from the staging folder and enqueues
        /// orphans into the queue it is handed; nil skips it.
        var recoverStagedRecordings: (@MainActor (PipelineQueue) -> Void)?
        var resolveOutputDir: @MainActor (OutputDirectoryResolver) -> URL = { $0.resolve() }

        static var production: Self {
            Self(
                logDir: nil,
                stagingDir: AppPaths.recordingsDir,
                recoverStagedRecordings: PipelineController.recoverStagedRecordings(into:),
            )
        }
    }

    @ObservationIgnored private let queueEnvironment: QueueEnvironment

    /// Called with the new queue whenever `rebuild()` replaces it, so a holder
    /// of the old one can follow. The active `WatchLoop` is one: it enqueues
    /// every recording it finishes into the queue it was given, so without
    /// following a folder change its recordings would land in the old folder
    /// through a queue nothing else shows.
    @ObservationIgnored var onQueueReplaced: ((PipelineQueue) -> Void)?

    /// The output-folder bookmark the current queue was built from, so a change
    /// of folder can be noticed without resolving the bookmark again.
    @ObservationIgnored private var queueBuiltFromBookmark: Data?

    /// The queue `makeQueue()` last built, the only one a folder change may
    /// replace: a queue assigned to `queue` from outside (a test's, with mock
    /// engines and its own logs) is left alone, as `ensureQueue()` leaves it.
    @ObservationIgnored private weak var builtQueue: PipelineQueue?

    /// Source of the currently-active engine. Set by `activate`; nil before then
    /// (so `makeQueue()` safely returns the current queue if called early — only
    /// reachable at process teardown, since `rebuild`/`ensureQueue` are driven by
    /// user actions while `AppState` is alive). Captures the owner weakly.
    private var engineProvider: (() -> (any TranscribingEngine)?)?

    init(
        settings: AppSettings,
        notifier: any AppNotifying,
        terminalJobStore: TerminalJobStore? = nil,
        queueEnvironment: QueueEnvironment = .production,
    ) {
        self.settings = settings
        self.notifier = notifier
        self.queueEnvironment = queueEnvironment
        self.outputDirectory = OutputDirectoryResolver(settings: settings, notifier: notifier)
        self.terminalJobStore = terminalJobStore
            ?? TerminalJobStore(
                path: (queueEnvironment.logDir ?? AppPaths.ipcDir).appendingPathComponent("terminal_jobs.json"),
            )
        self.queue = PipelineQueue(logDir: queueEnvironment.logDir)
    }

    /// Wire the active-engine source. Called once from `AppState.init` after its
    /// stored-property init.
    func activate(engineProvider: @escaping () -> (any TranscribingEngine)?) {
        self.engineProvider = engineProvider
        observeOutputFolder()
    }

    // MARK: - Queue lifecycle

    /// Rebuild the queue against the current settings + active engine and
    /// re-install the job-state callbacks. The watch-start path calls this so a
    /// fresh session picks up the latest settings/engine, but it must not swap the
    /// queue while that queue still owns unfinished work. Two hazards:
    ///
    /// 1. An in-flight job (`isProcessing`): the running job's `processTask` holds
    ///    the current queue alive to completion, so a replacement would
    ///    `loadSnapshot()` the same job (reset from `.transcribing`/`.diarizing`/
    ///    `.generatingProtocol` back to `.waiting`) and process it a second time.
    /// 2. A job parked at `.speakerNamingPending`: `isProcessing` is already false
    ///    (`processNext` returned), but the naming session's in-memory data lives
    ///    only on the current queue. A fresh queue restores the parked job from
    ///    the snapshot without that data, orphaning the user's pending naming.
    ///
    /// A third case needs the job states rather than `isProcessing`: a late
    /// confirm or re-run from the naming dialog runs in a task of the naming
    /// session, so the job sits in `.diarizing` or `.generatingProtocol` while
    /// `isProcessing` is false and nothing is parked for naming. A fresh queue
    /// would pick that job up from the snapshot and run it a second time.
    ///
    /// So the queue is replaced only when every job it holds is finished. Note
    /// this defers queue-captured settings (engine choice, diarization, VAD,
    /// numSpeakers) to the next idle watch-start rather than refreshing them
    /// automatically; live engine language/vocabulary still sync separately onto
    /// the shared engine instances meanwhile. The output folder is the
    /// exception, see `rebuildIfOutputFolderChanged()`.
    ///
    /// `recoversStagedRecordings: false` skips the staging-folder recovery the
    /// new queue would otherwise run, for a rebuild that can come while a
    /// recording is in progress.
    func rebuild(recoversStagedRecordings: Bool = true) {
        guard canReplaceQueue else {
            logger.info("Skipping queue rebuild: a job is unfinished or awaiting speaker naming")
            return
        }
        // Adopted from, rather than re-read from the file, whenever the queue
        // being replaced is one this controller built. That is exactly the case
        // where it has already loaded the snapshot and holds the newer state in
        // memory, and `queue === builtQueue` is the same test the folder change
        // uses. The first queue is not one of those, so it reads the file, which
        // is how a run interrupted by a crash or a quit comes back. Decided here
        // and not by the caller: every path that swaps the queue needs it, and a
        // parameter would let one of them pass a queue nobody checked.
        let replaced = queue === builtQueue ? queue : nil
        let built = makeQueue(recoversStagedRecordings: recoversStagedRecordings, adoptingJobsFrom: replaced)
        // `makeQueue` hands back the current queue when no engine is wired yet.
        // The bookkeeping below has to describe a queue that was actually
        // installed, so a no-op must not advance it.
        guard built !== queue else { return }
        queue = built
        // Recorded here and not in `makeQueue`, which is also called for its
        // return value alone: doing it there left `builtQueue` pointing at a
        // throwaway that died immediately, and the folder-change rebuild then
        // stopped firing for the rest of the session while the bookmark it
        // compares against had already advanced.
        queueBuiltFromBookmark = settings.customOutputDirBookmark
        builtQueue = built
        configureCallbacks()
        onQueueReplaced?(queue)
    }

    /// Whether the queue holds no unfinished work: nothing processing, and
    /// every job done or failed (a job parked for naming is neither).
    private var canReplaceQueue: Bool {
        !queue.isProcessing && queue.jobs.allSatisfy(\.state.isTerminal)
    }

    /// Rebuild the queue when the output folder has changed since it was built,
    /// as soon as it holds no unfinished work.
    ///
    /// A queue writes into the folder it was built with and holds that folder's
    /// security scope for its lifetime, so without this every import and
    /// recording would keep landing in the old folder while Settings shows the
    /// new one. A job already running finishes where it started; the rebuild
    /// waits for it (`observeOutputFolder` re-checks on every job change).
    /// Compared by bookmark data, not by resolving it: the check runs on every
    /// job change, and a resolution can touch a slow volume.
    func rebuildIfOutputFolderChanged() {
        guard queue === builtQueue,
              settings.customOutputDirBookmark != queueBuiltFromBookmark,
              canReplaceQueue
        else { return }
        logger.info("Output folder changed, rebuilding the pipeline queue")
        // Without the staging recovery: unlike a launch or a watch start, a
        // folder change can come mid-recording, and the recovery tells a
        // crashed recording from a live one only by how recently its files were
        // written, so a track that has been silent for half a minute would be
        // re-mixed or deleted underneath its writer. The recovery exists for
        // what an earlier process left behind, and the next watch start runs
        // it again.
        rebuild(recoversStagedRecordings: false)
    }

    /// Re-check `rebuildIfOutputFolderChanged()` whenever the chosen folder
    /// changes, and, while a change is still waiting for the queue to finish,
    /// whenever the queue's jobs or processing flag change.
    /// `withObservationTracking` fires once, so each firing re-arms.
    private func observeOutputFolder() {
        withObservationTracking {
            let pending = settings.customOutputDirBookmark != queueBuiltFromBookmark
            if pending {
                _ = queue.isProcessing
                _ = queue.jobs
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.rebuildIfOutputFolderChanged()
                self?.observeOutputFolder()
            }
        }
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
    func makeQueue(
        recoversStagedRecordings: Bool = true,
        adoptingJobsFrom replaced: PipelineQueue? = nil,
    ) -> PipelineQueue {
        guard let engine = engineProvider?() else { return queue }
        let q = PipelineQueue(
            engine: engine,
            diarizationFactory: { [self] in makeFluidDiarizer(mode: settings.diarizerMode) },
            diarizationFactoryWithMode: { [self] mode in makeFluidDiarizer(mode: mode) },
            protocolGeneratorFactory: { [self] in makeProtocolGenerator() },
            // Captured by value: this is the moment the destination of every job
            // this queue will run is decided, so a fallback is reported here and
            // not from `effectiveOutputDir`, which `body` reads on every render.
            outputDir: queueEnvironment.resolveOutputDir(outputDirectory),
            logDir: queueEnvironment.logDir,
            stagingDir: queueEnvironment.stagingDir,
            diarizeEnabled: settings.diarize,
            echoDedupEnabled: settings.echoDedupEnabled,
            echoCancellationEnabled: { [settings] in settings.echoCancellationEnabled },
            numSpeakers: settings.numSpeakers,
            micLabel: settings.micName,
            includeFullTranscriptInProtocol: settings.includeFullTranscriptInProtocol,
            saveRawTranscriptSeparately: settings.saveRawTranscriptSeparately,
            transcriptOutputOptionsProvider: { [settings] in
                TranscriptOutputOptions(
                    includeFullTranscriptInProtocol: settings.includeFullTranscriptInProtocol,
                    saveRawTranscriptSeparately: settings.saveRawTranscriptSeparately,
                )
            },
            speakerMatcherFactory: { SpeakerMatcher() },
            vadConfig: settings.vadEnabled ? VADConfig(threshold: settings.vadThreshold) : nil,
            recognitionStatsLog: RecognitionStatsLog(),
            terminologyNormalizer: { [weak settings] in
                TerminologyNormalizer(rulesText: settings?.terminologyRulesText ?? "")
            },
            stageTimingLog: StageTimingLog(),
            terminalJobStore: terminalJobStore,
            securityScope: queueEnvironment.securityScope,
        )
        if let replaced {
            q.adoptJobs(of: replaced)
        } else {
            q.loadSnapshot()
        }
        if recoversStagedRecordings { queueEnvironment.recoverStagedRecordings?(q) }
        q.refreshKnownSpeakerNames()
        return q
    }

    /// Fire-and-forget: dir scan + per-file attr probes run off-main so app
    /// startup (and the first call to `enqueueFiles`) isn't blocked by a slow
    /// filesystem. Recovered jobs appear in `queue.jobs` once the scan returns.
    private static func recoverStagedRecordings(into q: PipelineQueue) {
        Task {
            // Rescue recordings whose writer was killed mid-stream (#379), then
            // hand off to the orphan scan which enqueues the results. Detached
            // so the dir scans + per-file rewrites/re-mixes run off-main and
            // don't block startup (same reason the orphan scan offloads its own
            // filesystem work). Order matters:
            //   1. repair unfinalized WAV headers so a crashed mic track reads,
            //   2. re-mix crashed recordings (raw app .tmp + mic) into a _mix.wav,
            //   3. delete any temp the re-mix couldn't use.
            // The staging folder comes from the queue, not from `AppPaths`: the
            // three calls below repair, re-mix and delete files, so a controller
            // built against another staging folder would otherwise reach into the
            // real one, which is exactly what injecting the folder was meant to
            // prevent.
            let staging = q.stagingDir
            await Task.detached(priority: .utility) {
                let repaired = WavHeaderRepair.repairUnfinalized(in: staging)
                if repaired > 0 { logger.info("Repaired \(repaired) unfinalized recording(s) on launch") }
                let recovered = DualSourceRecorder.recoverCrashedRecordings(in: staging)
                if recovered > 0 { logger.info("Recovered \(recovered) crashed recording(s) on launch") }
                DualSourceRecorder.cleanupTempFiles(recordingsDir: staging)
            }.value
            await q.recoverOrphanedRecordings()
        }
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
                ClaudeCLIProtocolGenerator(
                    claudeBin: settings.claudeBin,
                    language: settings.protocolLanguage,
                    anthropicAPIKey: settings.claudeAPIKey.isEmpty ? nil : settings.claudeAPIKey,
                )
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
                // Record-only fleet flow: a separate host reprocesses recordings
                // captured elsewhere. Anchor the output basename on the sidecar's
                // real meeting-start time, not this reprocessing moment.
                meetingStartTime: sidecar?.startedAt,
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
        // Tagged `.rpc`: nobody was looking at a dialog, so a row from here must
        // not read as a human decision in the recognition log.
        queue.completeSpeakerNaming(jobID: jobID, result: result, source: .rpc)
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
                if job.state.isTerminal { return .completed(JobStatusDTO(job: job)) }
            } else if let record = terminalJobStore.lookup(jobID: jobID) {
                return .completed(record) // already reaped from the live queue
            }
            try? await Task.sleep(for: pollInterval)
        }
        // Final read: a job that went terminal in the last sub-interval window
        // (or while we were enqueuing with maxWaitSeconds==0) is completed, not
        // timed out.
        let final = jobStatus(forID: jobID)
        if let final, final.state.isTerminal { return .completed(final) }
        return .timedOut(final)
    }
}

/// Outcome of a blocking `transcribeAndWait`. The RPC layer maps `noFile` → 400,
/// `completed` → 200, `timedOut` → 202.
enum BlockingTranscribeResult {
    case noFile
    case completed(JobStatusDTO)
    case timedOut(JobStatusDTO?)

    /// The job this result refers to, if any (nil only for `.noFile`). Lets the
    /// RPC layer record the created job under an Idempotency-Key.
    var jobID: UUID? {
        switch self {
        case .noFile: nil
        case let .completed(dto): UUID(uuidString: dto.jobID)
        case let .timedOut(dto): dto.flatMap { UUID(uuidString: $0.jobID) }
        }
    }
}
