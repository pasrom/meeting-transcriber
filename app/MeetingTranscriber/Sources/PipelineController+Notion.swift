import Foundation

extension PipelineController {
    /// The first queue is otherwise built by a user action, so a failed or
    /// interrupted export, meeting notes that failed, or a failed cloud
    /// transcription would have no retry row after a relaunch. Restore only a
    /// terminal snapshot so displaying the rows starts no pending work.
    func restorePendingNotionExports() {
        guard let saved = try? PipelineSnapshot.load(from: queueEnvironment.logDir),
              saved.contains(where: { $0.isHeldAfterCompletion || $0.isCloudFailure }),
              saved.allSatisfy(\.state.isTerminal) else { return }
        rebuild(recoversStagedRecordings: false)
    }
}
