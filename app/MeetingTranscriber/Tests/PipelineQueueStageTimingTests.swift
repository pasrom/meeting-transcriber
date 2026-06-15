@testable import MeetingTranscriber
import XCTest

@MainActor
final class PipelineQueueStageTimingTests: XCTestCase {
    private func makeJob() -> PipelineJob {
        PipelineJob(
            meetingTitle: "Test Meeting",
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }

    /// Drives the state machine through the timed stages plus a `.diarizing`
    /// self-transition (the inline speaker-count rerun) and the naming pause,
    /// asserting the log records exactly one event per real stage: the naming
    /// wait is excluded and the self-transition is not double-counted.
    func testCapturesOneEventPerStageExcludingNamingAndSelfTransition() async throws {
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pq_stage_timing_\(UUID())")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let logPath = logDir.appendingPathComponent("stage_timing.jsonl")
        let log = StageTimingLog(path: logPath)
        let queue = PipelineQueue(logDir: logDir, stageTimingLog: log)

        let job = makeJob()
        queue.insertJobForTesting(job)

        queue.updateJobState(id: job.id, to: .transcribing)
        queue.updateJobState(id: job.id, to: .diarizing)
        queue.updateJobState(id: job.id, to: .diarizing) // inline rerun self-transition: must not re-log
        queue.updateJobState(id: job.id, to: .speakerNamingPending) // leaves .diarizing -> logs diarizing
        queue.updateJobState(id: job.id, to: .generatingProtocol) // naming pause not timed -> no event
        queue.updateJobState(id: job.id, to: .done) // leaves protocol -> logs protocol

        // Appends run in a per-stage Task; poll until they land.
        var events: [StageTimingEvent] = []
        for _ in 0 ..< 200 {
            events = await log.loadRecent(within: 30 * 86400)
            if events.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(events.count, 3, "one event per real stage; naming pause + self-transition excluded")
        XCTAssertEqual(
            Set(events.map(\.stage)), [.transcribing, .diarizing, .generatingProtocol],
        )
        XCTAssertEqual(
            events.count { $0.stage == .diarizing }, 1,
            "the .diarizing self-transition must not produce a second diarizing event",
        )
    }
}
