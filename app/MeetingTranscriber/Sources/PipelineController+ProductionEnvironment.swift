import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineController")

/// How `QueueEnvironment` is wired in production, with the staging-folder
/// recovery it hands each new queue. Split out of `PipelineController.swift` to
/// keep that file under the `file_length` limit, as `AppSettings+Computed` and
/// `AudioMixer+AssetFallback` are. Pure move; no behavioural difference from
/// declaring these inline.
extension PipelineController.QueueEnvironment {
    static var production: Self {
        Self(
            logDir: nil,
            stagingDir: AppPaths.recordingsDir,
            recoverStagedRecordings: PipelineController.recoverStagedRecordings(into:),
        )
    }
}

extension PipelineController {
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
}
