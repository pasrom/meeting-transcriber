import Foundation
@testable import MeetingTranscriber

/// A `PipelineController.QueueEnvironment` confined to one directory.
enum IsolatedQueueEnvironment {
    /// Its own staging folder and no staging recovery, so a controller built
    /// here cannot read or write the installed app's recordings. The three
    /// suites that build controllers repeated this literal; a forgotten
    /// `recoverStagedRecordings: nil` would let a test scan the real folder.
    @MainActor
    static func make(
        logDir: URL, initialQueue: PipelineQueue? = nil,
    ) -> PipelineController.QueueEnvironment {
        .init(
            logDir: logDir,
            stagingDir: logDir.appendingPathComponent("staging", isDirectory: true),
            recoverStagedRecordings: nil,
            initialQueue: initialQueue,
        )
    }
}
