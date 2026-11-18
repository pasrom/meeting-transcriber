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
        let held: Set<String>
        do {
            held = try PipelineQueue.heldTrackKeys(of: PipelineSnapshotStore.latestJobs(in: queue.logDir) ?? [])
        } catch {
            logger.warning("Retention pass skipped: the queue snapshot could not be read")
            return
        }
        // Not `resolve()`: that reports an unreachable folder, which is news
        // where output is written, not on a pass at launch or on the hour.
        let root = outputDirectory.current
        let scope = queueSecurityScope
        let scoped = scope.start(root) ? root : nil
        defer { scoped.map(scope.stop) }
        let placeholder = queue
        await recordingRetention.sweep(.init(
            excludedPaths: { [weak placeholder] in held.union(placeholder?.retentionExcludedPaths ?? []) },
            scopeRoot: scoped,
            securityScope: scope,
        ))
    }

    func startRecordingRetention() {
        recordingRetention.heldPaths = { [weak self] in self?.queue.retentionExcludedPaths ?? [] }
        observeRetentionSettings()
        scheduleRetentionSweeps()
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
