import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerNamingSession")

/// The injected naming handler that stands in for the dialog in tests and
/// headless runs. Split out of `SpeakerNamingSession+Late.swift` to keep both
/// files under the lint cap.
extension SpeakerNamingSession {
    /// Re-invoke the injected naming handler after the job reached
    /// `.speakerNamingPending`. Mirrors the late-rerun re-invocation so the test
    /// path runs the exact same `completeSpeakerNaming` flow the production UI
    /// does. Captures `self` strongly for the op duration (bounded); the delegate
    /// stays weak. No-op when no handler is set (the interactive/production path).
    ///
    /// The handler stands in for the dialog, but it cannot see a refusal the
    /// way a user sees the dialog's message, and the RPC caller sees its 404.
    /// So a refused answer for a job still waiting is logged, put on the job as
    /// a warning, and then the auto-names are accepted for it: what the stale
    /// cleanup would do a day later, without the job sitting pending, and
    /// anything awaiting it, until then. A refusal because the job is no longer
    /// waiting needs no answer and is only logged.
    func invokeHandler(jobID: UUID, data: SpeakerNamingData) {
        guard let handler = speakerNamingHandler, delegate?.isStillQueued(jobID) ?? true else { return }
        startLateWork(jobID: jobID) {
            let result = await handler(data)
            // The handler stands in for the dialog, so it reports as the dialog.
            guard let refusal = self.completeSpeakerNaming(jobID: jobID, result: result, source: .dialog) else {
                return
            }
            logger.warning("Naming handler answer refused: \(String(describing: refusal), privacy: .public)")
            guard refusal != .notAwaitingNaming else { return }
            self.delegate?.addWarning(id: jobID, refusal.message)
            self.completeSpeakerNaming(jobID: jobID, result: .skipped, source: .headless)
        }
    }
}
