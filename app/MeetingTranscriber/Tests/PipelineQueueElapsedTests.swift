@testable import MeetingTranscriber
import XCTest

@MainActor
final class PipelineQueueElapsedTests: XCTestCase {
    func testStartingAnotherTimedStageDoesNotResetFirstJobElapsed() throws {
        let (queue, first, second) = try makeQueueWithTwoJobs()
        queue.updateJobState(id: first, to: .transcribing)
        let sample = ContinuousClock.now + .seconds(10)
        let before = queue.elapsedSeconds(forJobID: first, at: sample)
        XCTAssertGreaterThan(before, 9)

        queue.updateJobState(id: second, to: .diarizing)

        XCTAssertEqual(queue.elapsedSeconds(forJobID: first, at: sample), before, accuracy: 0.001)
        XCTAssertGreaterThan(queue.elapsedSeconds(forJobID: second, at: sample), 9)
    }

    func testEndingAnotherTimedStageDoesNotFreezeFirstJob() throws {
        let (queue, first, second) = try makeQueueWithTwoJobs()
        queue.updateJobState(id: first, to: .transcribing)
        queue.updateJobState(id: second, to: .diarizing)
        let sample = ContinuousClock.now + .seconds(10)
        let before = queue.elapsedSeconds(forJobID: first, at: sample)

        queue.updateJobState(id: second, to: .speakerNamingPending)

        XCTAssertEqual(queue.elapsedSeconds(forJobID: first, at: sample), before, accuracy: 0.001)
        XCTAssertEqual(queue.elapsedSeconds(forJobID: second, at: sample), 0)
    }

    func testStageChangeResetsOnlyThatJobsElapsed() async throws {
        let (queue, first, second) = try makeQueueWithTwoJobs()
        queue.updateJobState(id: first, to: .transcribing)
        queue.updateJobState(id: second, to: .transcribing)
        let sample = ContinuousClock.now + .seconds(10)
        let secondBefore = queue.elapsedSeconds(forJobID: second, at: sample)
        try await Task.sleep(for: .milliseconds(50))
        let firstBefore = queue.elapsedSeconds(forJobID: first, at: sample)

        queue.updateJobState(id: first, to: .diarizing)

        XCTAssertGreaterThan(firstBefore - queue.elapsedSeconds(forJobID: first, at: sample), 0.03)
        XCTAssertEqual(queue.elapsedSeconds(forJobID: second, at: sample), secondBefore, accuracy: 0.001)
    }

    func testPendingTerminalAndCancelledJobsHaveNoElapsedTime() throws {
        let (queue, first, second) = try makeQueueWithTwoJobs()
        let sample = ContinuousClock.now + .seconds(10)
        XCTAssertEqual(queue.elapsedSeconds(forJobID: first, at: sample), 0)

        queue.updateJobState(id: first, to: .diarizing)
        XCTAssertGreaterThan(queue.elapsedSeconds(forJobID: first, at: sample), 9)
        queue.updateJobState(id: first, to: .speakerNamingPending)
        XCTAssertEqual(queue.elapsedSeconds(forJobID: first, at: sample), 0)
        queue.updateJobState(id: first, to: .done)
        XCTAssertEqual(queue.elapsedSeconds(forJobID: first, at: sample), 0)

        queue.updateJobState(id: second, to: .transcribing)
        queue.cancelJob(id: second)
        XCTAssertEqual(queue.elapsedSeconds(forJobID: second, at: sample), 0)
    }

    private func makeQueueWithTwoJobs() throws -> (PipelineQueue, UUID, UUID) {
        let dir = try makeTempDirectory(prefix: "pipeline_elapsed_test")
        let queue = PipelineQueue(logDir: dir)
        let first = PipelineJob(
            meetingTitle: "First", appName: "Teams",
            mixPath: dir.appendingPathComponent("first.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let second = PipelineJob(
            meetingTitle: "Second", appName: "Zoom",
            mixPath: dir.appendingPathComponent("second.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(first)
        queue.enqueue(second)
        return (queue, first.id, second.id)
    }
}
