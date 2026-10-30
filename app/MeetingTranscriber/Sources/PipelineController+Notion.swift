import Foundation

extension PipelineController {
    /// The first queue is otherwise built by a user action, so a failed or
    /// interrupted export would have no retry row after a relaunch. Any other
    /// saved job keeps waiting for that action: building the queue would resume it.
    func restorePendingNotionExports() {
        guard let saved = try? PipelineSnapshot.load(from: queueEnvironment.logDir),
              saved.contains(where: \.hasPendingNotionExport),
              saved.allSatisfy({ $0.state == .done }) else { return }
        rebuild(recoversStagedRecordings: false)
    }
}
