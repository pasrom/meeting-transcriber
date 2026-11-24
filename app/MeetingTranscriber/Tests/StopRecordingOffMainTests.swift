@testable import MeetingTranscriber
import XCTest

/// Every stop of a recording does its file work (reading the tracks back,
/// mixing, writing the mix, a record-only move) off the main actor, not only
/// the stop a quit makes. Run on the main actor it froze the app for as long
/// as the mix took, about 17 s for an hour in a debug build.
///
/// The recorder double's mix waits on a gate the test opens. A mix run on the
/// main thread holds the test there until the gate's own deadline, so by the
/// time the test looks again the mix has finished: that is the red result.
@MainActor
final class StopRecordingOffMainTests: XCTestCase {
    /// Waits until the mix has begun and checks the main actor got here while
    /// it is still running.
    private func assertTheMixRunsOffTheMainActor(
        _ recorder: SlowMixRecorder, file: StaticString = #filePath, line: UInt = #line,
    ) async {
        await waitFor(recorder.mixesStarted == 1, timeout: .seconds(3))
        XCTAssertEqual(recorder.mixesStarted, 1, "precondition: the stop never began its mix", file: file, line: line)
        XCTAssertEqual(
            recorder.mixesFinished, 0, "the mix ran on the main actor and held it until it finished",
            file: file, line: line,
        )
    }

    func testAManualStopLeavesTheMainActorFreeWhileTheMixRuns() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "stop_off_main_manual"))
        let recorder = SlowMixRecorder()
        let loop = makeSlowMixLoop(recorder: recorder, queue: queue)
        try await loop.startMicrophoneRecording()

        let stopping = Task { await loop.stopManualRecording() }
        await assertTheMixRunsOffTheMainActor(recorder)
        XCTAssertTrue(loop.hasWorkBeforeQuit, "a quit now would not wait for the mix")
        XCTAssertTrue(queue.jobs.isEmpty)

        recorder.gate.release()
        await stopping.value
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(loop.state, .idle)
        XCTAssertFalse(loop.hasWorkBeforeQuit)
    }

    func testAnAutoRecordingThatEndsLeavesTheMainActorFreeWhileTheMixRuns() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "stop_off_main_auto"))
        let recorder = SlowMixRecorder()
        let loop = makeSlowMixLoop(recorder: recorder, queue: queue, detector: FinishedMeetingDetector())
        addTeardownBlock { loop.stop() }
        loop.start()

        await assertTheMixRunsOffTheMainActor(recorder)
        XCTAssertTrue(loop.hasWorkBeforeQuit)
        // The level poll reads this; a stopped recorder reports channels that
        // deliver nothing, which would read as a capture fault for the whole mix.
        XCTAssertNil(loop.activeRecorder, "the stopped recorder is still exposed to the level poll")

        recorder.gate.release()
        await waitFor(queue.jobs.count == 1, timeout: .seconds(3))
        XCTAssertEqual(queue.jobs.count, 1)
    }

    /// Stop Watching cancels the watch task in the middle of the mix. The
    /// recording must still be enqueued, once.
    func testStopWatchingDuringTheMixStillEnqueuesTheRecordingOnce() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "stop_off_main_cancel"))
        let recorder = SlowMixRecorder()
        let loop = makeSlowMixLoop(recorder: recorder, queue: queue, detector: FinishedMeetingDetector())
        loop.start()
        await waitFor(recorder.mixesStarted == 1, timeout: .seconds(3))

        loop.stop()
        XCTAssertTrue(loop.hasWorkBeforeQuit, "a stopped loop still finishing a recording must hold a quit")
        recorder.gate.release()
        await waitFor(queue.jobs.count == 1, timeout: .seconds(3))
        await waitFor(!loop.hasWorkBeforeQuit, timeout: .seconds(3))

        XCTAssertEqual(recorder.mixesFinished, 1)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertFalse(loop.hasWorkBeforeQuit)
    }

    /// A quit that arrives while a manual stop is mixing waits for that mix
    /// instead of finding nothing to stop and going on without the job.
    func testAQuitDuringAManualStopWaitsForItsMix() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "stop_off_main_quit"))
        let recorder = SlowMixRecorder()
        let loop = makeSlowMixLoop(recorder: recorder, queue: queue)
        try await loop.startMicrophoneRecording()
        let stopping = Task { await loop.stopManualRecording() }
        await waitFor(recorder.mixesStarted == 1, timeout: .seconds(3))

        var quitReturned = false
        let quitting = Task {
            await loop.finishForQuit()
            quitReturned = true
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertFalse(quitReturned, "the quit went on while the recording was still being mixed")

        recorder.gate.release()
        await quitting.value
        await stopping.value
        XCTAssertEqual(queue.jobs.count, 1, "the quit returned before the recording was enqueued")
        XCTAssertEqual(recorder.mixesStarted, 1, "the quit must not stop the recorder a second time")
    }

    /// Stop Watching drops the controller's loop while that loop is still
    /// mixing the recording it stopped. A quit then has to find it.
    func testAQuitAfterStopWatchingWaitsForTheMixStillRunning() async throws {
        let recorder = SlowMixRecorder()
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "stop_off_main_controller"),
            makeDetector: { FixedMeetingDetector() },
            makeRecorder: { recorder },
        )
        let started = await controller.startWatching()
        XCTAssertEqual(started, .changed, "precondition")
        await waitFor({ controller.watchLoop?.state == .recording }, timeout: .seconds(10))
        let queue = try XCTUnwrap(controller.watchLoop?.pipelineQueue)

        _ = await controller.stopWatching()
        await waitFor(recorder.mixesStarted == 1, timeout: .seconds(3))
        XCTAssertEqual(recorder.mixesStarted, 1, "precondition: the stop never began its mix")
        XCTAssertTrue(controller.hasWorkBeforeQuit, "a quit now would not wait for the mix")

        let quitting = Task { await controller.finishForQuit() }
        await Task.yield()
        recorder.gate.release()
        await quitting.value

        XCTAssertEqual(queue.jobs.count, 1, "the quit returned before the recording was enqueued")
        XCTAssertFalse(controller.hasWorkBeforeQuit)
    }

    /// Start Watching again while the loop Stop Watching let go of is still
    /// mixing. The start rebuilds the queue and recovers staged recordings, so
    /// it waits for that mix: rebuilt first, the old loop would enqueue into a
    /// retired queue the app no longer shows or saves.
    func testAWatchStartDuringTheMixOfAStoppedLoopWaitsForIt() async throws {
        let recorder = SlowMixRecorder()
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "stop_off_main_restart"),
            makeDetector: { FixedMeetingDetector() },
            makeRecorder: { recorder },
        )
        addTeardownBlock { await controller.finishForQuit() }
        // Runs first: the restarted loop records too, and its stop needs the
        // gate opened a second time.
        addTeardownBlock { recorder.gate.release() }
        _ = await controller.startWatching()
        await waitFor({ controller.watchLoop?.state == .recording }, timeout: .seconds(10))
        _ = await controller.stopWatching()
        await waitFor(recorder.mixesStarted == 1, timeout: .seconds(3))
        XCTAssertEqual(recorder.mixesStarted, 1, "precondition: the stop never began its mix")

        var restarted = false
        let restarting = Task {
            _ = await controller.startWatching()
            restarted = true
        }
        // Real time, not yields: the start awaits the permission gate and the
        // queue's construction before it would reach the rebuild.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(restarted, "the start went on while the stopped loop was still mixing")

        recorder.gate.release()
        await restarting.value
        let queue = try XCTUnwrap(controller.watchLoop?.pipelineQueue)
        XCTAssertEqual(
            queue.jobs.count { $0.mixPath?.lastPathComponent == "slow_mix.wav" }, 1,
            "the stopped loop's recording is missing from the queue the restart installed",
        )
    }

    /// A loop Stop Watching let go of finds, while the app quits, that its
    /// recording captured nothing. That is no error to report in the middle
    /// of a quit, the same as for the current loop.
    func testAQuitDoesNotReportAnEmptyRecordingOfAStoppedLoop() async throws {
        let recorder = SlowMixRecorder()
        recorder.stopError = .noAudioData
        let notifier = RecordingNotifier()
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "stop_off_main_empty"),
            notifier: notifier,
            makeDetector: { FixedMeetingDetector() },
            makeRecorder: { recorder },
        )
        _ = await controller.startWatching()
        await waitFor({ controller.watchLoop?.state == .recording }, timeout: .seconds(10))
        _ = await controller.stopWatching()
        await waitFor(recorder.mixesStarted == 1, timeout: .seconds(3))
        XCTAssertEqual(recorder.mixesStarted, 1, "precondition: the stop never began its mix")

        let quitting = Task { await controller.finishForQuit() }
        // Let the quit begin before the mix ends, as it does in the app.
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        recorder.gate.release()
        await quitting.value

        XCTAssertEqual(notifier.calls.filter { $0.title == "Error" }.count, 0, "an empty recording was reported mid-quit")
    }
}
