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

    /// A queue whose stage-timing log lives in a fresh temp directory, which
    /// is also where a test puts the tracks it hands the queue.
    private func makeTimedQueue(
        canceller: StubCanceller? = nil,
    ) throws -> (queue: PipelineQueue, log: StageTimingLog, dir: URL) {
        let dir = try makeTempDirectory(prefix: "pq_stage_timing")
        let log = StageTimingLog(path: dir.appendingPathComponent("stage_timing.jsonl"))
        return (PipelineQueue.withEchoCanceller(canceller, logDir: dir, stageTimingLog: log), log, dir)
    }

    /// Appends run in a per-stage Task; poll until `count` of them landed.
    private func waitForEvents(_ log: StageTimingLog, count: Int) async -> [StageTimingEvent] {
        await waitFor { await log.loadRecent(within: 30 * 86400).count >= count }
        return await log.loadRecent(within: 30 * 86400)
    }

    /// Drives the state machine through the timed stages plus a `.diarizing`
    /// self-transition (the inline speaker-count rerun) and the naming pause,
    /// asserting the log records exactly one event per real stage: the naming
    /// wait is excluded and the self-transition is not double-counted.
    func testCapturesOneEventPerStageExcludingNamingAndSelfTransition() async throws {
        let (queue, log, _) = try makeTimedQueue()
        let job = makeJob()
        queue.insertJobForTesting(job)

        queue.updateJobState(id: job.id, to: .transcribing)
        queue.updateJobState(id: job.id, to: .diarizing)
        queue.updateJobState(id: job.id, to: .diarizing) // inline rerun self-transition: must not re-log
        queue.updateJobState(id: job.id, to: .speakerNamingPending) // leaves .diarizing -> logs diarizing
        queue.updateJobState(id: job.id, to: .generatingProtocol) // naming pause not timed -> no event
        queue.updateJobState(id: job.id, to: .done) // leaves protocol -> logs protocol

        let events = await waitForEvents(log, count: 3)

        XCTAssertEqual(events.count, 3, "one event per real stage; naming pause + self-transition excluded")
        XCTAssertEqual(
            Set(events.map(\.stage)), [.transcribing, .diarizing, .generatingProtocol],
        )
        XCTAssertEqual(
            events.count { $0.stage == .diarizing }, 1,
            "the .diarizing self-transition must not produce a second diarizing event",
        )
    }

    // MARK: - Echo cancellation inside the transcribing stage

    /// Echo cancellation runs inside the transcribing stage and costs several
    /// times what transcription does. Folded into the transcribing event it
    /// inflated that stage's average for every later job, cancelled or not,
    /// and left the cost itself unmeasured, which is the number the feature's
    /// default has to be decided against. It is its own event, and the
    /// transcribing event is what is left once it is taken out.
    ///
    /// The job's `echo.cancellationSeconds` is the same clock reading as the
    /// event. Two clocks around two spans drifted apart by the self-check and
    /// the file swap, and a driver comparing the per-job number against the
    /// Settings average would have been comparing measurements of different
    /// things.
    func testEchoCancellationIsLoggedAsItsOwnStageAndLeftOutOfTranscribing() async throws {
        let (queue, log, dir) = try makeTimedQueue(
            canceller: StubCanceller(medianReduction: 30, delay: .milliseconds(300)),
        )
        let tracks = try EchoTestAudio.writeTrackPair(into: dir)
        let job = makeJob()
        queue.insertJobForTesting(job)
        queue.seedAffectedEchoVerdict(jobID: job.id)

        queue.updateJobState(id: job.id, to: .transcribing)
        _ = try await queue.cancelEchoOnMicTrack(
            jobID: job.id, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )
        queue.updateJobState(id: job.id, to: .diarizing)
        queue.updateJobState(id: job.id, to: .done)

        let events = await waitForEvents(log, count: 3)
        let echo = try XCTUnwrap(events.first { $0.stage == .echoCancelling }, "the run is logged on its own")
        let transcribing = try XCTUnwrap(events.first { $0.stage == .transcribing })
        XCTAssertGreaterThanOrEqual(echo.wallClockSeconds, 0.3)
        XCTAssertEqual(echo.audioSeconds, 2, accuracy: 0.01, "the cost is normalisable by what it processed")
        // Relative, not an absolute bound: what is left of the transcribing
        // stage here is file copies and a self-check, milliseconds that a
        // sanitizer build stretches several-fold. Without the carve-out the
        // transcribing event would carry the run plus that remainder, so it
        // would exceed the echo event, which is what this falsifies.
        XCTAssertLessThan(
            transcribing.wallClockSeconds, echo.wallClockSeconds,
            "the transcribing event must not carry the cancellation run as well",
        )
        let onJob = try XCTUnwrap(queue.jobs.first?.echo?.cancellationSeconds)
        XCTAssertEqual(onJob, echo.wallClockSeconds, accuracy: 1e-6, "one clock reading, two homes")
    }

    /// No run, no event: a missing model returns before anything is processed,
    /// and logging its few microseconds would drag the measured cost toward
    /// zero for exactly the installs where the feature did nothing.
    func testNoEchoCancellationEventWhenNothingRan() async throws {
        let (queue, log, dir) = try makeTimedQueue(canceller: nil)
        let job = makeJob()
        queue.insertJobForTesting(job)
        let unused = dir.appendingPathComponent("absent.wav")

        queue.updateJobState(id: job.id, to: .transcribing)
        _ = try await queue.cancelEchoOnMicTrack(jobID: job.id, appURL: unused, micURL: unused, micDelay: 0)
        queue.updateJobState(id: job.id, to: .diarizing)

        _ = await waitForEvents(log, count: 1)
        // Each append is its own Task, so a wrongly logged echo event could
        // land after the transcribing one; give it the chance to before
        // asserting it is not there.
        try await Task.sleep(for: .milliseconds(100))
        let events = await log.loadRecent(within: 30 * 86400)
        XCTAssertEqual(events.map(\.stage), [.transcribing])
    }
}
