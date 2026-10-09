@testable import MeetingTranscriber
import XCTest

/// Starts that were already under way when the quit began start nothing.
@MainActor
final class QuitStartRefusalTests: XCTestCase {
    // MARK: - Starts already under way when the quit begins

    /// A manual start past its permission check, waiting for its recorder,
    /// when the quit begins: it must not start a recording the quit then cuts
    /// to nothing.
    func testAManualStartWaitingForItsRecorderDoesNotStartAfterTheQuitBegan() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "quit_edge_manual_start"))
        let recorder = StopCountingRecorder()
        let gate = MainActorGate()
        let loop = WatchLoop(
            recorderFactory: {
                await gate.wait()
                return recorder
            },
            pipelineQueue: queue,
            pollInterval: 0.02,
        )
        loop.permissionChecker = { .allHealthy }
        let start = Task { try await loop.startMicrophoneRecording() }
        await waitFor(gate.hasWaiter, timeout: .seconds(3))

        await loop.finishForQuit()
        gate.open()
        let outcome = await start.result

        XCTAssertFalse(recorder.startCalled, "a recording started after the quit had begun")
        XCTAssertThrowsError(try outcome.get())
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    /// The same for a meeting the watch loop has just detected: the quit
    /// cancels the loop, and a recording it starts anyway ends at once,
    /// empty, and fails with an error the user is notified of mid-quit.
    func testAMeetingDetectedJustBeforeTheQuitIsNotRecorded() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "quit_edge_auto_start"))
        let recorder = StopCountingRecorder()
        let gate = MainActorGate()
        let loop = WatchLoop(
            detector: FixedMeetingDetector(),
            recorderFactory: {
                await gate.wait()
                return recorder
            },
            pipelineQueue: queue,
            pollInterval: 0.02,
            endGracePeriod: 0.05,
        )
        loop.permissionChecker = { .allHealthy }
        loop.start()
        await waitFor(gate.hasWaiter, timeout: .seconds(3))

        let finishing = Task { await loop.finishForQuit() }
        await Task.yield()
        gate.open()
        await finishing.value

        XCTAssertFalse(recorder.startCalled, "a recording started after the quit had begun")
        XCTAssertNotEqual(loop.state, .error)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    /// An auto watch start parked on the microphone prompt when the quit
    /// begins must not start watching once the prompt is answered: the guard
    /// that stops it had no test.
    func testAWatchStartParkedOnThePromptGivesUpOnceTheAppQuits() async throws {
        let gate = MainActorGate()
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "quit_edge_watch_start"),
            ensureMicAccess: {
                await gate.wait()
                return true
            },
            permissionHealth: .allHealthy,
        )
        controller.toggleWatching(userInitiated: false)
        await waitFor(gate.hasWaiter, timeout: .seconds(3))
        XCTAssertTrue(gate.hasWaiter, "precondition: the start never reached the microphone prompt")

        let finishing = Task { await controller.finishForQuit() }
        await Task.yield()
        gate.open()
        await finishing.value
        _ = await controller.joinStart()

        XCTAssertNil(controller.watchLoop, "watching started after the quit had begun")
        XCTAssertFalse(controller.isWatching)
    }

    // MARK: - A recording the quit ended before it captured anything

    /// A meeting whose recording had only just started when the quit came
    /// has no audio, and its stop throws `noAudioData`. During a quit that is
    /// nothing recorded, not an error: the loop used to report it as one, and
    /// the user got an "Error" notification in the middle of quitting.
    func testAnAutoRecordingEmptyAtQuitIsNotReportedAsAnError() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "quit_empty_auto"))
        let recorder = MockRecorder() // no mix path: its stop throws noAudioData
        let loop = WatchLoop(
            detector: FixedMeetingDetector(), recorderFactory: { recorder }, pipelineQueue: queue,
            pollInterval: 0.02, endGracePeriod: 0.05,
        )
        loop.permissionChecker = { .allHealthy }
        var phases: [WatchLoop.State] = []
        loop.onStateChange = { _, new in phases.append(new) }
        loop.start()
        await waitFor(loop.state == .recording, timeout: .seconds(3))
        XCTAssertEqual(loop.state, .recording, "precondition: the loop never started recording")

        await loop.finishForQuit()

        XCTAssertTrue(recorder.stopCalled)
        XCTAssertFalse(phases.contains(.error), "an empty recording at quit was reported as an error: \(phases)")
        XCTAssertNil(loop.lastError)
    }

    func testAManualRecordingEmptyAtQuitIsNotReportedAsAnError() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "quit_empty_manual"))
        let recorder = MockRecorder()
        let loop = WatchLoop(recorderFactory: { recorder }, pipelineQueue: queue, pollInterval: 0.02)
        loop.permissionChecker = { .allHealthy }
        try await loop.startMicrophoneRecording()

        await loop.finishForQuit()

        XCTAssertTrue(recorder.stopCalled)
        XCTAssertNil(loop.lastError, "an empty recording at quit was reported as an error")
    }
}
