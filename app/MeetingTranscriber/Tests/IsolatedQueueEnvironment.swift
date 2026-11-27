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
            speakersDB: logDir.appendingPathComponent("speakers.json"),
            recognitionStatsLog: logDir.appendingPathComponent("recognition_log.jsonl"),
            stageTimingLog: logDir.appendingPathComponent("stage_timing.jsonl"),
            recoverStagedRecordings: nil,
            // A fixed answer: the real probe writes into the temp folder on
            // every controller a test builds.
            probeKeptRecordingCodec: { .available },
            // No sweep: a controller whose settings keep the default output
            // folder would list the real one at launch.
            compactionWorker: RecordingCompactionWorker(steps: .live.with(\.sweep) { _, _, _ in 0 }),
            initialQueue: initialQueue,
        )
    }
}
