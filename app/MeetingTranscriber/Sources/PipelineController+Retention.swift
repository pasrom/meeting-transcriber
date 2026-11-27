import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineController+Retention")

/// When recording-retention passes run: at launch, hourly, after a queue
/// rebuild and once any retention or storage-limit setting has settled after a change. A finished job
/// starts one of its own from the queue.
extension PipelineController {
    /// How often a pass runs on its own. Retention is counted in days, so an
    /// hour late is never noticeable.
    static let retentionSweepInterval: Duration = .seconds(3600)

    /// How long the settings must stay unchanged before a change runs a pass,
    /// so a value the stepper only passes through never acts.
    static let retentionSettleDelay: Duration = .seconds(1)

    /// The registry in this controller's log folder, and a cleaner reading
    /// the retention and storage-limit settings live on every pass, so a
    /// change applies without a rebuild.
    static func makeRecordingRetention(
        logDir: URL, settings: AppSettings, notifier: any AppNotifying,
    ) -> RecordingRetention {
        let notifyLimitReached: (Int64, Int64) -> Void = { total, limit in
            let note = storageLimitNotification(totalBytes: total, limitBytes: limit)
            notifier.notify(title: note.title, body: note.body)
        }
        let showStatus: (RecordingStorageStatus?) -> Void = { [weak settings] status in
            settings?.recordingStorageStatus = status
        }
        return RecordingRetention(
            registry: RecordingRetentionRegistry(
                path: logDir.appendingPathComponent(RecordingRetentionRegistry.filename),
            ),
            settings: { [weak settings] in
                RecordingRetentionSettings(
                    enabled: settings?.recordingRetentionEnabled ?? false,
                    days: settings?.recordingRetentionDays ?? 0,
                )
            },
            storageLimit: { [weak settings] in
                guard let settings else { return .off }
                return .gigabytes(settings.recordingStorageLimitGB, enabled: settings.recordingStorageLimitEnabled)
            },
            alarm: settings.recordingStorageAlarm,
            onLimitReached: notifyLimitReached,
            onStatus: showStatus,
        )
    }

    /// What the user is told when the recordings go over the storage limit.
    static func storageLimitNotification(totalBytes: Int64, limitBytes: Int64) -> (title: String, body: String) {
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal) }
        let hours = Int(RecordingStorageLimitPolicy.gracePeriod / 3600)
        return (
            "Recording storage limit reached",
            "Recordings use \(format(totalBytes)) of the \(format(limitBytes)) limit. In \(hours) hours, the "
                + "oldest recordings whose meeting notes are saved will be deleted until they fit.",
        )
    }

    /// Run a retention pass for the current queue, which knows the output
    /// folder's scope and which tracks its unfinished jobs hold.
    ///
    /// Before a queue built from the settings is installed (watching off, at
    /// launch) the controller holds a placeholder that has not loaded the
    /// snapshot, so it cannot know that a job the restore would bring back
    /// still needs a recording. The pass then reads the snapshot itself and
    /// keeps every track a job in it names; an unreadable snapshot skips the
    /// pass. It takes the output folder's scope the way a built queue does, so
    /// with a custom folder's access held, entries under an earlier folder are
    /// kept as unreachable here too.
    func sweepRetainedRecordings() async {
        guard queue.recordingRetention == nil else {
            await queue.sweepRetainedRecordings()
            return
        }
        // Off, the pass would keep everything; skip the snapshot read and the
        // bookmark resolve it needs.
        guard recordingRetention.isActive, !recordingRetention.registry.entries.isEmpty else { return }
        await withoutBuiltQueue("Retention pass", readingSnapshot: true) { reach in
            await recordingRetention.sweep(.init(
                excludedPaths: reach.excludedPaths, scopeRoot: reach.scopeRoot, securityScope: reach.securityScope,
            ))
        }
    }

    /// What a pass or a run started before a built queue is installed works
    /// with: the output folder from `outputDirectory.current` and its scope,
    /// held while `body` runs, and as held paths every track an unfinished
    /// job in the snapshot names, besides the placeholder queue's own. An
    /// unreadable snapshot skips `body` with a line naming `what`. Without
    /// `readingSnapshot` (nothing a held path could protect) the snapshot is
    /// not read.
    private func withoutBuiltQueue(
        _ what: String, readingSnapshot: Bool, _ body: @MainActor (PlaceholderReach) async -> Void,
    ) async {
        var held: Set<String> = []
        if readingSnapshot {
            do {
                held = try PipelineQueue.heldTrackKeys(of: PipelineSnapshotStore.latestJobs(in: queue.logDir) ?? [])
            } catch {
                logger.warning("\(what, privacy: .public) skipped: the queue snapshot could not be read")
                return
            }
        }
        // Not `resolve()`: that reports an unreachable folder, which is news
        // where output is written, not on a pass at launch or on the hour.
        let root = outputDirectory.current
        let scope = queueSecurityScope
        let scoped = scope.start(root) ? root : nil
        defer { scoped.map(scope.stop) }
        let placeholder = queue
        await body(PlaceholderReach(
            excludedPaths: { [weak placeholder, held] in held.union(placeholder?.retentionExcludedPaths ?? []) },
            root: root, scopeRoot: scoped, securityScope: scope,
        ))
    }

    /// See `withoutBuiltQueue`.
    private struct PlaceholderReach {
        let excludedPaths: () -> Set<String>
        let root: URL
        let scopeRoot: URL?
        let securityScope: SecurityScopeAccess
    }

    func startRecordingRetention() {
        // The compactor's entry in work counts as held: a pass that came due
        // during the run would otherwise delete the WAV it is reading, or the
        // copy it has just listed and named.
        recordingRetention.heldPaths = { [weak self] in
            guard let self else { return [] }
            return queue.retentionExcludedPaths.union(recordingCompaction.inWorkPaths)
        }
        observeRetentionSettings()
        scheduleRetentionSweeps()
    }

    // MARK: - Compaction

    /// The compactor on the retention registry, reading the FLAC setting and
    /// the settings retention acts on live.
    static func makeRecordingCompaction(
        retention: RecordingRetention, settings: AppSettings, worker: RecordingCompactionWorker,
    ) -> RecordingCompaction {
        RecordingCompaction(
            registry: retention.registry,
            isEnabled: { [weak settings] in settings?.compressKeptRecordings ?? false },
            retentionSettings: { [weak retention] in
                retention?.effectiveSettings ?? RecordingRetentionSettings(enabled: false, days: 0)
            },
            worker: worker,
        )
    }

    /// Probe the codec off the main actor, then run once for the entries a
    /// quit or a missing codec left marked. The run's sweep of leftover
    /// partial copies happens whatever the probe found. The controller keeps
    /// the task it returns as `compactionLaunch`.
    func startRecordingCompaction() -> Task<Void, Never> {
        recordingCompaction.heldPaths = { [weak self] in self?.queue.retentionExcludedPaths ?? [] }
        let probe = queueEnvironment.probeKeptRecordingCodec
        return Task { [weak self] in
            let status = await Task.detached(priority: .utility) { probe() }.value
            guard let self else { return }
            recordingCompaction.codecStatus = status
            switch status {
            case let .unavailable(reason):
                logger.warning("Kept recording codec: none (\(reason, privacy: .public))")

            default:
                logger.info("Kept recording codec: \(status.codecName, privacy: .public)")
            }
            await compactRecordings()
        }
    }

    /// Run the compactor for the current queue, or, before a built queue is
    /// installed, with what a retention pass at that point uses: the tracks
    /// the snapshot's unfinished jobs name as held, and the output folder's
    /// scope on `outputDirectory.current`, held until the run returns. An
    /// unreadable snapshot skips the run. With nothing marked the run only
    /// sweeps, and the snapshot is not read.
    func compactRecordings() async {
        guard queue.recordingCompaction == nil else {
            await queue.compactRecordings()
            return
        }
        let readingSnapshot = recordingCompaction.awaitingCount > 0
        await withoutBuiltQueue("Compaction run", readingSnapshot: readingSnapshot) { reach in
            await recordingCompaction.run(.init(
                excludedPaths: reach.excludedPaths,
                // No queue holds a finished job yet; the restore reads the
                // snapshot, whose finished jobs are not run again.
                repointJobAudio: { _, _, _ in },
                outputRoot: reach.root,
                scopeRoot: reach.scopeRoot,
                securityScope: reach.securityScope,
            ))
        }
    }

    /// Start a pass once either retention setting has stopped changing for
    /// `retentionSettleDelay`, so switching it on or shortening the period
    /// clears the backlog without waiting for the next finished job, while a
    /// value the stepper only passes through (holding minus from 30 runs
    /// through 0) never acts. Observed through the cleaner's own settings
    /// read, which touches both settings. Re-arms on each firing, like the
    /// output-folder observation.
    private func observeRetentionSettings() {
        withObservationTracking {
            _ = recordingRetention.currentSettings
            _ = recordingRetention.currentStorageLimit
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                observeRetentionSettings()
                recordingRetention.afterSettling(for: Self.retentionSettleDelay) { [weak self] in
                    self?.recordingRetention.settle()
                    await self?.sweepRetainedRecordings()
                }
            }
        }
    }

    /// One pass at launch and one per `retentionSweepInterval`, for recordings
    /// that come due while nothing else happens. Before a built queue is
    /// installed it reads the snapshot itself; see `sweepRetainedRecordings`. Held weakly across the sleep,
    /// so a controller that goes away (in tests, never in the app) is not kept
    /// alive for an hour by its timer.
    private func scheduleRetentionSweeps() {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweepRetainedRecordings()
                guard self != nil else { return }
                try? await Task.sleep(for: Self.retentionSweepInterval)
            }
        }
    }
}
