import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingCompaction")

/// Converts the WAV tracks of finished recordings to lossless FLAC in the
/// output folder, after their job is done.
///
/// Its only input is `RecordingRetentionRegistry.entries`: it never picks a
/// recording by listing a folder (the one listing is the sweep of its own
/// leftover partial copies). Two triggers share one path: a job reaching
/// `.done` with `AppSettings.compressKeptRecordings` on marks its entry
/// (`RetainedRecording.awaiting`) and starts a run, and a run at launch picks
/// up every marked entry, so a quit in the middle of an encode only delays
/// that recording. The "Compress Existing Recordings" action is a third
/// trigger on the same `run` (`RecordingCompactionPlan.Request.everyEntry`):
/// every entry still listing a WAV track, with the setting on or off.
///
/// Per track: the file facts and the encode, decode-compare and sync run off
/// the main actor (`RecordingCompactionWorker`); then one main-actor turn with
/// no suspension rechecks the entry, lists the copy's final name in the
/// registry, and only then renames the partial to it; then the folder is
/// synced and the WAV removed, and only after that is the WAV forgotten. So
/// no file under a track name is ever untracked, and the WAV is the last
/// thing to go. After an entry's tracks, its recording sidecar's `files` is
/// rewritten to the names as they are now. The sequence and what each crash
/// point leaves are in `docs/architecture/pipeline.md`.
@Observable
@MainActor
final class RecordingCompaction {
    /// How old a partial copy must be before the sweep removes it. A run in
    /// progress names its own, so this only bounds leftovers of a run that
    /// was cut off, whatever the setting says now.
    static let partialMaxAge: TimeInterval = 24 * 3600

    @ObservationIgnored let registry: RecordingRetentionRegistry

    /// What the launch probe found; the runs do nothing but the sweep until
    /// it says `available`.
    var codecStatus: KeptRecordingCodecStatus = .unknown

    /// True while a run is going.
    private(set) var isRunning = false
    /// The log line of the last run that looked at entries.
    private(set) var lastRunSummary: String?
    /// How far the run going on is, in tracks; nil before its selection and
    /// between runs.
    private(set) var progress: RecordingCompactionProgress?
    /// What the last run the user asked for did, for Settings; nil while one
    /// is going and before the first.
    private(set) var lastRequestedRun: RecordingCompactionSummary?

    private(set) var requestedRun: RequestedRun = .idle

    /// Paths of the entry being worked on, its copies' names and its partial
    /// copies, standardized. Composed into retention's held paths, so a pass
    /// during the run keeps the entry whole, and kept out of the sweep.
    private(set) var inWorkPaths: Set<String> = []

    /// Paths held by the unfinished jobs of the queue currently in use, set
    /// by the controller, as for `RecordingRetention.heldPaths`.
    @ObservationIgnored var heldPaths: () -> Set<String> = { [] }

    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let retentionSettings: () -> RecordingRetentionSettings
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let worker: RecordingCompactionWorker
    @ObservationIgnored private let rename: (URL, URL) throws -> Void
    @ObservationIgnored private let report: (RecordingCompactionSummary) -> Void

    @ObservationIgnored private var running: Task<Void, Never>?
    /// The pass going on inside `running`, its own task so a cancel stops it
    /// and not the loop: a request that joins after the cancel still runs.
    @ObservationIgnored private var pass: Task<Void, Never>?
    /// Every request waits here, the first one too, so a cancel before its
    /// pass starts finds it; the loop takes the next pass out in the same
    /// turn it sets `currentRequest` and `pass`.
    @ObservationIgnored private var pending: RecordingCompactionPlan.Backlog<Context>? {
        didSet { refreshRequestedRun() }
    }

    @ObservationIgnored private var cancelRequested = false
    /// The request of the pass going on, nil between passes.
    @ObservationIgnored private var currentRequest: RecordingCompactionPlan.Request? {
        didSet { refreshRequestedRun() }
    }

    /// The output folder of the run going on, nil between runs. A run keeps
    /// the folder it was started with when the queue moves to another one.
    @ObservationIgnored private var runRoot: URL?

    /// `isEnabled` is the FLAC setting, read live; `retentionSettings` the
    /// settings retention acts on, so an entry about to be deleted is not
    /// converted first. `rename` runs on the main actor in the commit turn
    /// and is injectable so a test can read the registry at that moment.
    /// `report` defaults to one public info line per run.
    init(
        registry: RecordingRetentionRegistry,
        isEnabled: @escaping () -> Bool,
        retentionSettings: @escaping () -> RecordingRetentionSettings,
        now: @escaping () -> Date = Date.init,
        worker: RecordingCompactionWorker = RecordingCompactionWorker(),
        rename: @escaping (URL, URL) throws -> Void = RecordingCompaction.renameExclusive,
        report: @escaping (RecordingCompactionSummary) -> Void = { logger.info("\($0.logLine, privacy: .public)") },
    ) {
        self.registry = registry
        self.isEnabled = isEnabled
        self.retentionSettings = retentionSettings
        self.now = now
        self.worker = worker
        self.rename = rename
        self.report = report
    }

    /// Whether a finished job should be converted, and a run started for it.
    var wantsWork: Bool {
        mayWork(.awaiting(.flac))
    }

    /// Whether a run for `request` converts anything: the probe found FLAC,
    /// and the setting allows it.
    private func mayWork(_ request: RecordingCompactionPlan.Request) -> Bool {
        codecStatus == .available && settingAllows(request)
    }

    /// The setting gates the automatic runs only; the user's run ignores it.
    private func settingAllows(_ request: RecordingCompactionPlan.Request) -> Bool {
        request.isExplicit || isEnabled()
    }

    /// How many recordings under `root` the explicit run would work on, for
    /// Settings, with the run's selection rules. By name only: no file of a
    /// recording is looked at on the main actor (the caller may resolve the
    /// output folder's bookmark, as the Output tab already does); what the
    /// files say (gone, evicted) is the run's to find and count.
    func compressibleCount(under root: URL) -> Int {
        RecordingCompactionPlan.select(registry.entries, request: .everyEntry, in: .init(
            outputRoot: root, now: now(), retention: retentionSettings(),
            environment: .byName(excludedPaths: heldPaths().union(inWorkPaths)),
        )).compressibleCount
    }

    /// Record that the run the user asked for could not start, for Settings.
    func recordRequestedRunNotStarted(_ reason: RecordingCompactionSummary.NotRun) {
        lastRequestedRun = RecordingCompactionSummary(explicit: true, notRun: reason)
    }

    /// Whether a run is expected to remove the WAV of a track `entry` lists
    /// beside its FLAC, so the storage limit counts the pair once
    /// (`RecordingRetention.pairResolves`): the entry in work, or one still
    /// marked as owed FLAC while the setting is on and the probe has not
    /// ruled FLAC out (the rule `markFinished` marks by, so the launch pass,
    /// which runs before the probe answers, counts a pair a quit left once),
    /// under the folder of the run going on or `idleRoot`, the folder the
    /// next run would be given.
    ///
    /// Known limit: a marked entry a run passes over (due under the age rule,
    /// held by a job that ended in an error), and a session whose probe never
    /// answers, still count the pair once while that lasts. So does a marked
    /// pair whose unlink failed, or met after the setting was switched off
    /// and on, or after a run returned early because its scope did not open:
    /// it waits for the next job to finish or the next launch, the only
    /// automatic events that start a run, or for the user's run.
    func pairResolves(_ entry: RetainedRecording, idleRoot: URL?) -> Bool {
        if RecordingRetentionPolicy.isInUse(entry, excludedPaths: inWorkPaths) { return true }
        guard entry.awaiting.contains(.flac), isEnabled(), codecStatus.unavailableReason == nil else { return false }
        let key = RecordingRetentionPolicy.pathKey(entry.root)
        return [runRoot, idleRoot].contains { $0.map(RecordingRetentionPolicy.pathKey) == key }
    }

    /// Mark the entry of a job that just reached `.done` under `root`, the
    /// output folder its queue writes to, as owed the conversion, while the
    /// setting asks for it. Returns whether a run should start now: not for
    /// a job with no entry there (an import). Marked even while the probe
    /// has not answered, so a launch run converts it once it has; not once
    /// the probe found no FLAC, since nothing would ever clear that mark.
    @discardableResult
    func markFinished(jobID: UUID, root: URL) -> Bool {
        guard isEnabled(), codecStatus.unavailableReason == nil else { return false }
        guard registry.markAwaiting(.flac, jobID: jobID, root: root) else {
            // Relocated under an output folder the setting has moved away
            // from since: no run here can reach it, so it stays WAV.
            if registry.entries.contains(where: { $0.jobID == jobID }) {
                logger.info("[\(PipelineJob.shortID(for: jobID), privacy: .public)] compaction_not_marked reason=other_output_folder")
            }
            return false
        }
        return wantsWork
    }

    /// Stop the run in progress after the step it is in, and drop a queued
    /// one. A copy not yet committed is removed; the entry stays marked.
    func cancel() {
        pending = nil
        stopPass()
    }

    /// Stop only the run the user asked for: the pass going on when it is
    /// that one, keeping what automatic requests owe, or, while it waits
    /// behind an automatic pass, its place in the queue, leaving that pass
    /// alone. What it leaves unconverted stays WAV.
    func cancelRequestedRun() {
        if currentRequest?.isExplicit == true {
            _ = RecordingCompactionPlan.Backlog.dropExplicit(from: &pending) // a repeat queued behind it
            stopPass()
        } else if RecordingCompactionPlan.Backlog.dropExplicit(from: &pending) {
            // Never started, so no pass writes its summary.
            lastRequestedRun = RecordingCompactionSummary(explicit: true, cancelled: true)
        }
    }

    private func stopPass() {
        guard let pass else { return }
        cancelRequested = true
        pass.cancel()
    }

    /// Written only when it changes: an equal write still redraws Settings.
    /// Waiting only behind a pass that is going: a request the loop has not
    /// taken yet, with no pass going, is as good as running.
    private func refreshRequestedRun() {
        let now: RequestedRun = if currentRequest?.isExplicit == true {
            .running
        } else if pending?.explicit == true {
            currentRequest == nil ? .running : .waiting
        } else {
            .idle
        }
        if now != requestedRun { requestedRun = now }
    }

    /// Run once, or join the run in progress and make sure another follows
    /// it with the newest context and what this request adds. Returns once
    /// the work asked for is done.
    func run(_ context: Context, request: RecordingCompactionPlan.Request = .awaiting(.flac)) async {
        if pending == nil {
            pending = .init(context: context, request: request)
        } else {
            pending?.add(context: context, request: request)
        }
        if let running {
            await running.value
            return
        }
        let task = Task(priority: .utility) { [self] in
            while true {
                // One turn, current before it leaves `pending` (`requestedRun`
                // never reads idle in between): a cancel from here finds it.
                var backlog = pending
                guard let next = RecordingCompactionPlan.Backlog.takeNext(from: &backlog) else { break }
                currentRequest = next.request
                pending = backlog
                let once = Task(priority: .utility) { [self] in await runOnce(next.context, request: next.request) }
                pass = once
                await once.value
                pass = nil
                currentRequest = nil
                // A cancel ends its own pass; what was queued after it runs.
                cancelRequested = false
            }
            running = nil
            isRunning = false
        }
        running = task
        isRunning = true
        await task.value
    }

    /// A cancel, or the setting switched off while an automatic run is
    /// going: the run stops after the step it is in, and what it has not done
    /// stays marked. The run the user asked for ignores the setting.
    private var isCancelled: Bool {
        cancelRequested || Task.isCancelled || !(currentRequest.map(settingAllows) ?? isEnabled())
    }

    private func inUse(_ context: Context) -> Set<String> {
        context.excludedPaths().union(heldPaths())
    }

    private func runOnce(_ context: Context, request: RecordingCompactionPlan.Request) async {
        runRoot = context.outputRoot
        var summary = RecordingCompactionSummary(explicit: request.isExplicit)
        if request.isExplicit { lastRequestedRun = nil }
        defer {
            runRoot = nil
            progress = nil
            if request.isExplicit {
                // Only a cancel that stopped something: one pressed after the
                // last track leaves nothing unconverted.
                if summary.skippedTracks[.cancelled] != nil { summary.cancelled = true }
                lastRequestedRun = summary
            }
        }
        // One scope for the whole run, on the object the caller resolved: a
        // queue rebuild can release the queue's own while the run is going.
        if let scopeRoot = context.scopeRoot {
            guard context.securityScope.start(scopeRoot) else {
                summary.notRun = .outputFolderNotOpened
                logger.warning("Compaction run skipped: the output folder's access could not be opened")
                return
            }
        }
        defer { context.scopeRoot.map(context.securityScope.stop) }

        let recordings = context.outputRoot.appendingPathComponent("recordings", isDirectory: true)
        // Whatever the setting says: a cut-off run's partial is a full-size
        // copy of private audio.
        summary.sweptPartials = await worker.sweep(
            recordings, olderThan: now().addingTimeInterval(-Self.partialMaxAge), keeping: inWorkPaths,
        )
        if summary.sweptPartials > 0 {
            logger.info("Compaction removed \(summary.sweptPartials, privacy: .public) leftover partial copies")
        }

        guard mayWork(request), !isCancelled else {
            summary.notRun = RecordingCompactionSummary.NotRun(codecStatus)
            summary.cancelled = summary.notRun == nil && isCancelled
            return
        }
        guard hasWork(for: request) else { return }
        defer {
            lastRunSummary = summary.logLine
            report(summary)
        }
        guard registry.persist() else {
            summary.registryNotSaved = true
            logger.warning("Compaction run skipped: the registry could not be saved")
            return
        }
        let selection = RecordingCompactionPlan.select(registry.entries, request: request, in: .init(
            outputRoot: context.outputRoot, now: now(), retention: retentionSettings(),
            environment: .live(excludedPaths: inUse(context), scopedRoot: context.scopeRoot),
        ))
        summary.skippedEntries = selection.skipped
        summary.outsideFolder = selection.outsideFolder
        // For Settings, which shows the user's run only.
        if request.isExplicit {
            progress = RecordingCompactionProgress(total: selection.candidates.reduce(0) { $0 + $1.tracks.count })
        }
        for candidate in selection.candidates {
            guard !isCancelled else {
                summary.cancelled = cancelRequested || Task.isCancelled
                break
            }
            summary.entries += 1
            await compact(candidate, kind: request.clearedMark, in: recordings, context: context, summary: &summary)
        }
    }

    // MARK: - One entry

    private func compact(
        _ candidate: RecordingCompactionPlan.Candidate,
        kind: CompactionKind,
        in recordings: URL,
        context: Context,
        summary: inout RecordingCompactionSummary,
    ) async {
        let jobID = candidate.jobID
        inWorkPaths = []
        defer { inWorkPaths = [] }
        // Set when something that may work next time stopped a track; the
        // mark stays then.
        var retry = false
        var namesChanged = false // this run changed what the entry lists
        let marked = registry.entry(of: jobID, under: candidate.root)?.awaiting.contains(kind) == true
        var attempted: Set<String> = []
        // The tracks are read from the registry before each one, not taken
        // from the selection: an AI-title rename during the run moves them,
        // and the entry follows the move.
        while let wav = nextTrack(of: jobID, under: candidate.root, scopeRoot: context.scopeRoot, skipping: attempted) {
            guard !isCancelled else {
                retry = true
                summary.cancelled = cancelRequested || Task.isCancelled
                break
            }
            attempted.insert(RecordingRetentionPolicy.pathKey(wav))
            guard let track = Track(wav, of: jobID) else { progress?.advance(); continue }
            inWorkPaths.formUnion([track.flac, track.partial].map(RecordingRetentionPolicy.pathKey))
            let outcome = await compactTrack(track, in: recordings, context: context)
            progress?.advance()
            switch outcome {
            case let .compressed(saved):
                summary.compressed += 1
                summary.bytesSaved += saved
                namesChanged = true

            case let .resumed(saved):
                summary.resumed += 1
                summary.bytesSaved += saved
                namesChanged = true

            case .forgotten:
                summary.forgotten += 1
                namesChanged = true

            case .nothing:
                break

            case let .skipped(reason):
                summary.skippedTracks[reason, default: 0] += 1
                // A recheck that failed because the entry gave the WAV up (a
                // rename, followed by the loop above, or a newer recording
                // on the path) leaves nothing to come back for.
                let givenUp = reason == .recheckFailed && registry.entry(listing: wav, for: jobID) == nil
                if !reason.isPermanent, !givenUp { retry = true }
            }
        }
        // An output folder that went away (an unplugged drive) makes every
        // track read as gone; that is no reason to give up on the recording.
        // Nor is a `recordings` folder that is not there or cannot be listed:
        // a volume detached from a custom mount point leaves that point as
        // an empty folder, so the root looks present (measured). The
        // condition retention uses before it takes files for gone.
        let recordingsListable = FileManager.default.isReadableFile(atPath: recordings.path)
        if !FileManager.default.fileExists(atPath: candidate.root.path) || !recordingsListable { retry = true }
        let finished = !retry && !isCancelled
        // When a name changed (also before a cancel), or a marked entry
        // finished (a crash before the rewrite left its mark, and old names);
        // an untouched sidecar, perhaps not downloaded, is not read here.
        if namesChanged || finished && marked { rewriteSidecar(jobID: jobID, root: candidate.root) }
        if finished, registry.clearAwaiting(kind, jobID: jobID, root: candidate.root) {
            summary.marksCleared += 1
        }
    }

    /// The first WAV track the entry lists now, directly in its root's
    /// `recordings` folder, that this run has not tried yet. The entry's
    /// paths join the in-work set as they are read, so retention holds what
    /// a rename moved too.
    private func nextTrack(of jobID: UUID, under root: URL, scopeRoot: URL?, skipping attempted: Set<String>) -> URL? {
        guard let entry = registry.entry(of: jobID, under: root) else { return nil }
        inWorkPaths.formUnion(entry.paths.map(RecordingRetentionPolicy.pathKey))
        let environment = RecordingRetentionPolicy.Environment.live(excludedPaths: [], scopedRoot: scopeRoot)
        return entry.paths.first { path in
            RecordingCompactionPlan.isWAVTrack(path)
                && !attempted.contains(RecordingRetentionPolicy.pathKey(path))
                && RecordingRetentionPolicy.isInRecordingsFolder(path, of: root, in: environment)
        }
    }

    /// The bytes saved are the WAV's size less its copy's.
    private enum TrackOutcome: Equatable {
        case compressed(saved: Int64), resumed(saved: Int64)
        case forgotten, nothing
        case skipped(RecordingCompactionPlan.TrackSkip)
    }

    /// One WAV track of an entry, with the names its copy goes through.
    private struct Track {
        let wav: URL
        let flac: URL
        let partial: URL
        let jobID: UUID

        init?(_ wav: URL, of jobID: UUID) {
            guard let flac = KeptRecordingCompressor.compressedURL(for: wav) else { return nil }
            self.wav = wav
            self.flac = flac
            partial = KeptRecordingCompressor.partialURL(for: flac)
            self.jobID = jobID
        }
    }

    private func compactTrack(_ track: Track, in recordings: URL, context: Context) async -> TrackOutcome {
        let (wav, flac, partial, jobID) = (track.wav, track.flac, track.partial, track.jobID)
        let destinationListed = registry.entry(listing: flac, for: jobID) != nil
        let facts = await worker.facts(wav, flac)
        switch RecordingCompactionPlan.action(for: facts, destinationListed: destinationListed) {
        case let .skip(reason):
            return .skipped(reason)

        case .nothingToDo:
            return .nothing

        case .forgetSource:
            registry.forget([wav], of: jobID)
            return .forgotten

        case .resume:
            // Both listed after a cut-off run: the copy must still be the
            // source's before the source goes.
            // Only a copy that decodes to other samples is a mismatch for
            // good; a cancel or a read error may not happen next time.
            do {
                try await worker.verify(flac, wav)
            } catch {
                return .skipped(Self.skip(for: error))
            }
            guard !isCancelled else { return .skipped(.cancelled) }
            guard registry.isPersisted, registry.entry(listing: flac, for: jobID) != nil,
                  let entry = registry.entry(listing: wav, for: jobID),
                  !RecordingRetentionPolicy.isInUse(entry, excludedPaths: inUse(context))
            else { return .skipped(.recheckFailed) }
            // The cut-off run may have stopped before it pointed the job at the copy.
            context.repointJobAudio(jobID, wav, flac)
            let saved = Self.savedBytes(source: facts.source, copy: Self.liveIdentity(flac))
            return await removeSource(of: track, in: recordings, context: context).map(TrackOutcome.skipped)
                ?? .resumed(saved: saved)

        case .encode:
            guard case let .regular(before) = facts.source else { return .nothing }
            do {
                try await worker.prepare(wav, partial)
            } catch {
                return .skipped(Self.skip(for: error))
            }
            // The verified copy, so the commit renames that file and no other.
            let verified = await worker.identity(partial)
            // An encoder that ignored the cancel still returns here: nothing
            // is committed after a cancel.
            guard !isCancelled else {
                _ = await worker.remove(partial)
                return .skipped(.cancelled)
            }
            guard let verified, commit(track, unchanged: before, verified: verified, context: context) else {
                _ = await worker.remove(partial)
                return .skipped(.recheckFailed)
            }
            return await removeSource(of: track, in: recordings, context: context).map(TrackOutcome.skipped)
                ?? .compressed(saved: Self.savedBytes(source: facts.source, copy: verified))
        }
    }

    /// Why writing or reading back a copy failed, as a skip. Only what the
    /// compressor found wrong with the file is permanent; a cancel or an I/O
    /// error (a full disk, a read error) may not happen next time.
    private static func skip(for error: any Error) -> RecordingCompactionPlan.TrackSkip {
        switch error {
        case let failure as KeptRecordingCompressor.Failure:
            return .init(failure)

        case is CancellationError:
            return .cancelled

        default:
            logger.warning("Compaction could not write or read a copy: \(error.localizedDescription, privacy: .private)")
            return .writeFailed
        }
    }

    /// The commit: one main-actor turn, no suspension. The entry must still
    /// list the WAV (an AI-title rename or a newer recording on the path
    /// stops that), no unfinished job may hold any of its paths, retention
    /// must not be about to delete it, the WAV must be the one compared, the
    /// partial the one verified, and the final name must be free. Then the
    /// copy's final name is listed before the rename creates it, so a crash
    /// in between leaves a listed path that does not exist (tolerated
    /// everywhere) and never an untracked file under a track name. False
    /// leaves the partial for the caller to remove.
    private func commit(
        _ track: Track,
        unchanged before: RecordingCompactionPlan.TrackFacts.Stamp,
        verified: RecordingCompactionPlan.FileIdentity,
        context: Context,
    ) -> Bool {
        let (wav, flac, partial, jobID) = (track.wav, track.flac, track.partial, track.jobID)
        guard registry.isPersisted,
              let entry = registry.entry(listing: wav, for: jobID),
              !RecordingRetentionPolicy.isInUse(entry, excludedPaths: inUse(context)),
              !RecordingRetentionPolicy.isDue(entry, now: now(), settings: retentionSettings()),
              Self.liveStamp(wav) == before,
              Self.liveIdentity(partial) == verified,
              !FileManager.default.fileExists(atPath: flac.path)
        else { return false }
        registry.register(jobID: jobID, paths: [flac], root: entry.root, recordedAt: entry.recordedAt)
        guard registry.isPersisted else {
            registry.forget([flac], of: jobID)
            return false
        }
        do {
            try rename(partial, flac)
        } catch {
            registry.forget([flac], of: jobID)
            logger.warning("Compaction could not rename a copy: \(error.localizedDescription, privacy: .private)")
            return false
        }
        context.repointJobAudio(jobID, wav, flac)
        return true
    }

    /// Sync the folder, so the copy's name is on the disk before the WAV's
    /// goes; check the entry still lists the WAV (an AI-title rename during
    /// the sync moved it, and its new name must not be forgotten) and that no
    /// job took it into use meanwhile (a re-import); remove it; and forget it
    /// only once it is gone. Nil when it was removed.
    private func removeSource(
        of track: Track, in recordings: URL, context: Context,
    ) async -> RecordingCompactionPlan.TrackSkip? {
        await worker.syncFolder(recordings)
        guard let entry = registry.entry(listing: track.wav, for: track.jobID),
              !RecordingRetentionPolicy.isInUse(entry, excludedPaths: inUse(context)),
              // The copy is there, right before its WAV goes.
              Self.liveIdentity(track.flac) != nil else { return .recheckFailed }
        guard await worker.remove(track.wav) else { return .writeFailed }
        registry.forget([track.wav], of: track.jobID)
        return nil
    }
}
