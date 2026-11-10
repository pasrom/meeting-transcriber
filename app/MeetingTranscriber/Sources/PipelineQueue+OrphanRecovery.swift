import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// Orphaned-recording recovery for `PipelineQueue`: the staging scan for
/// recordings no job tracks, and the jobs it creates for them. Its own file
/// because `PipelineQueue+Recovery.swift` reached the `file_length` cap.
extension PipelineQueue {
    // MARK: - Orphaned Recording Recovery

    /// Scan `recordingsDir` for `*_mix.wav` files not tracked by any loaded job.
    /// Creates recovery jobs for untracked recordings younger than `maxAge`.
    /// Skips files the pipeline is already finished with, successfully or not
    /// (tracked in processed_recordings.json).
    ///
    /// The directory scan + per-file `attributesOfItem` calls run on a
    /// detached task — startup callers don't block the UI on a potentially
    /// slow filesystem (e.g. iCloud-backed recordings dir). Mutations to
    /// `jobs` and the snapshot still happen on the main actor.
    func recoverOrphanedRecordings(
        recordingsDir: URL,
        maxAge: TimeInterval = 86400,
    ) async {
        await adoptOrphanedRecordings(scanForOrphanedRecordings(recordingsDir: recordingsDir, maxAge: maxAge))
    }

    /// The recordings in `recordingsDir` that no job of this queue, no run in
    /// this process and no ledger entry accounts for, as of the call.
    func scanForOrphanedRecordings(
        recordingsDir: URL,
        maxAge: TimeInterval = 86400,
    ) async -> [PairedRecordingResolver.Group] {
        // One-time migration: seed processed list with existing recordings
        // Only for the default recordings directory (not test overrides)
        if recordingsDir == AppPaths.recordingsDir {
            await processedLedger.migrate(recordingsDir: recordingsDir)
        }

        // Read here, on the main actor, before the detached hop: the registry
        // is main-actor isolated, and reading it from inside the detached task
        // would be a different question anyway, asked later.
        let accountedFor = accountedForMixPaths()
        let ledger = processedLedger

        // Off-main: directory scan + processed-list read + per-file
        // attributesOfItem probes + filtering all happen here.
        return await Task.detached(priority: .utility) {
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
                guard !accountedFor.contains(stdPath) else { return false }
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
    }

    /// The mix paths a job of this queue or a run in this process already has,
    /// which the scan skips and the adoption checks again.
    private func accountedForMixPaths() -> Set<String> {
        Set(jobs.compactMap { $0.mixPath?.standardizedFileURL.path }).union(inFlightRuns.claimedAudioPaths)
    }

    /// Give each scanned orphan a job of its own.
    func adoptOrphanedRecordings(_ scanned: [PairedRecordingResolver.Group]) {
        // Asked again, because the scan was out on another task: a recording
        // the watch loop enqueued, or another queue started, meanwhile was in
        // neither set the scan checked, and a second job for it would end in
        // an error. One cancelled meanwhile has left the list, but its cancel
        // is in the ledger. The ledger read is on the main actor, so it is
        // skipped when the scan found nothing, the usual answer.
        let accountedFor = scanned.isEmpty ? [] : accountedForMixPaths().union(processedLedger.load())
        let candidates = scanned.filter { group in
            group.mix.map { !accountedFor.contains($0.standardizedFileURL.path) } ?? false
        }

        // Left in staging for the active queue's next recovery: the one its
        // build ran, or after a folder-change rebuild (which runs none), the
        // next watch start or launch. Taking them on here would process each
        // one on a queue nobody sees, and a second time on the active one.
        guard !candidates.isEmpty, !isRetired else { return }

        for group in candidates {
            guard let mixURL = group.mix else { continue }
            var job = PipelineJob(
                meetingTitle: "Recovered Recording (\(group.stem))",
                appName: "Unknown",
                mixPath: mixURL,
                appPath: group.app,
                micPath: group.mic,
                micDelay: 0,
            )
            stampTranscriptOutputOptions(on: &job)
            jobs.append(job)
            eventLog.append(jobID: job.id, event: "recovered", from: nil, to: .waiting)
        }
        saveSnapshot()
        logger.info("Recovered \(candidates.count) orphaned recording(s)")
        triggerProcessing()
    }
}
