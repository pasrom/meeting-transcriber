import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SnapshotWriter")

/// Owns the pipeline-queue snapshot write so a stalled `replaceItemAt`
/// (Spotlight `mds_stores` rename deadlock on macOS 26) blocks only this
/// actor's executor — never the UI, RPC, or watch loop.
///
/// The detached task in `PipelineQueue.saveSnapshot` calls `await write(...)`
/// across this actor boundary. The hop is a *real* suspension (cross-actor),
/// which sidesteps Swift Concurrency's synchronous-start optimization on
/// `Task.detached` that would otherwise let the body run on the caller's
/// thread until the first genuine await.
actor SnapshotWriterActor {
    func write(
        jobs: [PipelineJob],
        to dir: URL,
        using writer: @Sendable ([PipelineJob], URL) throws -> Void,
    ) {
        do {
            try writer(jobs, dir)
        } catch {
            logger.error("Failed to write queue snapshot: \(error)")
        }
    }
}
