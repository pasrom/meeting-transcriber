import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProcessedRecordingsLedger")

/// File-backed ledger of mix-file paths the pipeline is finished with, backing
/// `PipelineQueue`'s orphan-recovery skip list.
///
/// Finished, not succeeded. A recording lands here once its job reached any
/// terminal state, and also when the user dismisses it. Recording the failures
/// is the point: one that fails deterministically, say a silent capture that
/// yields an empty transcript, would otherwise be re-picked as an orphan on
/// every launch and fail again, with a notification each time. Re-importing by
/// hand is the intended retry and never consults this list.
///
/// Pure persistence over one JSON file (`processed_recordings.json` in
/// `logDir`): a JSON array of standardized file paths (`[String]`), written
/// atomically and restricted to owner-only (0600) like the other
/// sensitive-JSON stores, since the paths embed the account username.
/// `PipelineQueue.recoverOrphanedRecordings` reads this set to skip recordings
/// that were already processed, so they aren't re-queued as orphans on the
/// next launch.
///
/// A value type with no back-references into queue state, so it needs no
/// delegate. It self-ensures `logDir` before writes (creating it only when
/// absent) rather than sharing the queue's cached `logDirCreated` flag.
struct ProcessedRecordingsLedger {
    let logDir: URL

    var path: URL {
        logDir.appendingPathComponent("processed_recordings.json")
    }

    /// Load the set of mix paths the pipeline is finished with. Returns an
    /// empty set when the file is missing or unreadable/corrupt.
    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: path),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths)
    }

    /// Record that the pipeline is finished with a job's mix file. Nil mixPath
    /// (paired imports without a `_mix.wav` source) is a no-op — there's no
    /// path to track for orphan recovery.
    func markProcessed(mixPath: URL?) {
        guard let mixPath else { return }
        var paths = load()
        paths.insert(mixPath.standardizedFileURL.path)
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(Array(paths))
            try data.write(to: path, options: .atomic)
            try? FileManager.default.restrictToOwner(path)
        } catch {
            logger.error("Failed to write processed recordings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-time migration: if no processed_recordings.json exists yet, seed it with
    /// all existing `_mix.wav` files so they don't get recovered on first launch after update.
    ///
    /// Dir scan + JSON encode + atomic write run on a detached task. The
    /// existence guard makes it a no-op (no detached task spawned) when the
    /// processed file already exists — which is the steady-state case.
    func migrate(recordingsDir: URL) async {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        ensureLogDir()
        let path = self.path
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
                try data.write(to: path, options: .atomic)
                try? FileManager.default.restrictToOwner(path)
                logger.info("Migration: seeded \(paths.count) existing recordings as processed")
            } catch {
                logger.error("Migration failed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }

    /// Ensure `logDir` exists before a write. Skips the `createDirectory`
    /// syscall when the directory already exists (the steady-state case, since
    /// the queue creates its log dir early), so no cached flag is needed.
    private func ensureLogDir() {
        guard !FileManager.default.fileExists(atPath: logDir.path) else { return }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }
}
