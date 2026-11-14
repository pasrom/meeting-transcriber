@testable import MeetingTranscriber
import XCTest

/// A quit through any path (the menu, Cmd-Q, logout, shutdown, an AppleScript
/// quit) stops watching and hands an in-flight recording to the pipeline
/// before the snapshot is flushed. Only the menu's Quit used to stop the watch
/// loop, and even that dropped a manual recording and let an auto-detected
/// one be finalized after the exit had begun.
@MainActor
final class QuitFinishesRecordingTests: XCTestCase {
    /// The watch loop and pipeline in the roles `AppState` gives them, without
    /// the rest of `AppState`.
    private final class LoopAndPipeline: AppTerminating {
        let loop: WatchLoop
        let pipeline: PipelineController

        init(loop: WatchLoop, pipeline: PipelineController) {
            self.loop = loop
            self.pipeline = pipeline
        }

        var hasWorkBeforeQuit: Bool {
            loop.hasWorkBeforeQuit || pipeline.hasPendingSnapshotWrites
        }

        func finishRecordingBeforeQuit() async {
            await loop.finishForQuit()
        }

        func flushSnapshotsBeforeQuit() async {
            await pipeline.awaitSnapshotFlushes()
        }

        func tearDownBeforeExit() {}
    }

    /// The mix of a long meeting, held open until the test lets it finish.
    /// A thread blocked in `wait()` stands for one busy mixing. The wait
    /// also ends on its own after `deadline`, so that a mix wrongly run on
    /// the main thread, where the test can no longer reach `release()`,
    /// cannot hang the suite: the test then fails instead.
    private final class MixGate: Sendable {
        static let deadline: Duration = .seconds(5)
        private let semaphore = DispatchSemaphore(value: 0)

        func wait() {
            _ = semaphore.wait(timeout: .now() + .seconds(Int(Self.deadline.components.seconds)))
        }

        func release() {
            semaphore.signal()
        }
    }

    /// A recorder whose stop does what the real one does at the end of a long
    /// meeting: a mix that takes as long as it takes, here until the test
    /// releases `gate`. `stop()` does it on the caller's thread, which on the
    /// quit path is the main thread; `stopOffMain()` does it on a thread of
    /// its own, as `DualSourceRecorder` does.
    private final class SlowMixRecorder: RecordingProvider {
        let gate = MixGate()
        private(set) var mixesFinished = 0

        func start(source _: RecordingSource, micDeviceUID _: String?, debugLogging _: Bool) {}

        func stop() -> RecordingResult {
            gate.wait()
            mixesFinished += 1
            return result()
        }

        func stopOffMain() async -> RecordingResult {
            let gate = gate
            await Task.detached { gate.wait() }.value
            mixesFinished += 1
            return result()
        }

        private func result() -> RecordingResult {
            RecordingResult(
                mixPath: URL(fileURLWithPath: "/tmp/slow_mix.wav"), appPath: nil, micPath: nil,
                micDelay: 0, recordingStartDate: Date(),
            )
        }
    }

    private func makeLoop(recorder: SlowMixRecorder, detector: any MeetingDetecting, queue: PipelineQueue) -> WatchLoop {
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
        )
        loop.permissionChecker = { .allHealthy }
        return loop
    }

    // MARK: - WatchLoop

    /// An auto-detected recording is finalized by the watch task after
    /// `stop()` returns; `finishForQuit` waits for that, so the job exists
    /// when it returns.
    func testAnAutoRecordingIsEnqueuedBeforeFinishForQuitReturns() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "quit_auto"))
        let (loop, recorder) = makeTestWatchLoop(detector: FixedMeetingDetector(), pipelineQueue: queue)
        loop.start()
        await waitFor(loop.state == .recording, timeout: .seconds(3))
        XCTAssertEqual(loop.state, .recording, "precondition: the loop never started recording")

        await loop.finishForQuit()

        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1, "the recording was not enqueued by the time the quit went on")
        XCTAssertFalse(loop.hasWorkBeforeQuit)
    }

    /// `stop()` drops a manual recording without stopping the recorder, which
    /// is what the menu's Quit used to call.
    func testAManualRecordingIsStoppedAndEnqueued() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "quit_manual"))
        let (loop, recorder) = makeTestWatchLoop(pipelineQueue: queue)
        try await loop.startMicrophoneRecording()
        XCTAssertTrue(loop.hasWorkBeforeQuit)

        await loop.finishForQuit()

        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertFalse(loop.isActive)
    }

    func testAnIdleLoopHasNothingToWaitFor() {
        let (loop, _) = makeTestWatchLoop()
        XCTAssertFalse(loop.hasWorkBeforeQuit)
    }

    // MARK: - Through the delegate

    /// The race the ordering exists for: the quit arrives while an
    /// auto-detected meeting is recording. The job that recording becomes has
    /// to be in the snapshot on disk when the quit is answered.
    func testTheSnapshotOnDiskAtReplyHoldsTheRecordingInFlightAtQuit() async throws {
        let dir = try makeTempDirectory(prefix: "quit_race")
        let pipeline = try makeIsolatedPipelineController(initialQueue: makeSlowSnapshotQueue(in: dir))
        let (loop, _) = makeTestWatchLoop(detector: FixedMeetingDetector(), pipelineQueue: pipeline.queue)
        loop.start()
        await waitFor(loop.state == .recording, timeout: .seconds(3))
        XCTAssertEqual(loop.state, .recording, "precondition: the loop never started recording")

        let delegate = AppDelegate()
        let termination = LoopAndPipeline(loop: loop, pipeline: pipeline)
        delegate.termination = termination
        let sender = QuitTestSender()
        var onDiskAtReply: [PipelineJob] = []
        let replied = expectation(description: "reply")
        sender.onReply = {
            onDiskAtReply = (try? PipelineSnapshot.load(from: dir)) ?? []
            replied.fulfill()
        }

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await fulfillment(of: [replied], timeout: 10)

        XCTAssertEqual(onDiskAtReply.count, 1, "the recording in flight at quit is missing from the snapshot on disk")
        XCTAssertEqual(onDiskAtReply.map(\.id), pipeline.queue.jobs.map(\.id))
    }

    /// The mix at the end of a long recording takes seconds (about 17 s for an
    /// hour in a debug build). Run on the main actor it held the main thread,
    /// so the timer that is meant to end the recording phase could not fire
    /// and the quit took as long as the mix did, whatever the budget said.
    private func assertTheBudgetHoldsWhileTheMixRuns(
        loop: WatchLoop, recorder: SlowMixRecorder, queue: PipelineQueue,
        file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        let pipeline = try makeIsolatedPipelineController(initialQueue: queue)
        let delegate = AppDelegate()
        delegate.recordingBudget = .milliseconds(200)
        delegate.termination = LoopAndPipeline(loop: loop, pipeline: pipeline)
        let sender = QuitTestSender()
        let replied = expectation(description: "reply")
        var mixesFinishedAtReply: Int?
        sender.onReply = {
            mixesFinishedAtReply = recorder.mixesFinished
            replied.fulfill()
        }
        let start = ContinuousClock.now

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater, file: file, line: line)
        await fulfillment(of: [replied], timeout: 10)

        // The gate is still closed here, so a mix that had finished before
        // the reply can only have been cut short by its own deadline, which
        // is what happens when it holds the main thread.
        XCTAssertEqual(
            mixesFinishedAtReply, 0,
            "the quit was answered only after the mix finished, so it waited for it", file: file, line: line,
        )
        // The verdict above is the event. This bound only catches a reply held
        // up by something other than the mix, so it sits well clear of the
        // budget and below the gate's own deadline, where a loaded machine
        // cannot trip it.
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(
            elapsed, MixGate.deadline - .seconds(1),
            "the quit took \(elapsed) to answer", file: file, line: line,
        )
        // Let the mix the quit left behind finish, so it cannot run into the
        // next test. That it does finish is also what shows a mix was in
        // flight when the budget ran out: a quit that never stopped the
        // recorder would have nothing to cut off and would pass the checks
        // above just as well.
        recorder.gate.release()
        await waitFor(recorder.mixesFinished == 1, timeout: .seconds(10))
        XCTAssertEqual(
            recorder.mixesFinished, 1,
            "the quit never stopped the recorder, so there was no mix for the budget to cut off", file: file, line: line,
        )
    }

    func testAManualRecordingsMixDoesNotHoldTheQuitPastItsBudget() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "quit_slow_mix_manual"))
        let recorder = SlowMixRecorder()
        let loop = makeLoop(recorder: recorder, detector: makeSilentDetector(), queue: queue)
        try await loop.startMicrophoneRecording()

        try await assertTheBudgetHoldsWhileTheMixRuns(loop: loop, recorder: recorder, queue: queue)
    }

    func testAnAutoRecordingsMixDoesNotHoldTheQuitPastItsBudget() async throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "quit_slow_mix_auto"))
        let recorder = SlowMixRecorder()
        let loop = makeLoop(recorder: recorder, detector: FixedMeetingDetector(), queue: queue)
        loop.start()
        await waitFor(loop.state == .recording, timeout: .seconds(3))
        XCTAssertEqual(loop.state, .recording, "precondition: the loop never started recording")

        try await assertTheBudgetHoldsWhileTheMixRuns(loop: loop, recorder: recorder, queue: queue)
    }

    // MARK: - WatchingController

    /// A manual start parked on the microphone prompt when the quit begins
    /// gives up once the prompt is answered, instead of starting a recording
    /// the exit would cut off.
    func testAManualStartParkedOnThePromptGivesUpOnceTheAppQuits() async throws {
        let gate = MainActorGate()
        let recorder = makeMockRecorder()
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "quit_parked_start"),
            ensureMicAccess: {
                await gate.wait()
                return true
            },
            permissionHealth: .allHealthy,
            // swiftlint:disable:next trailing_closure
            makeRecorder: { recorder },
        )
        let start = try XCTUnwrap(controller.beginManualRecording(.microphone))
        await waitFor(gate.hasWaiter, timeout: .seconds(3))
        XCTAssertTrue(gate.hasWaiter, "precondition: the start never reached the microphone prompt")
        XCTAssertTrue(controller.hasWorkBeforeQuit)

        let finishing = Task { await controller.finishForQuit() }
        await Task.yield()
        gate.open()
        let result = await start.value
        await finishing.value

        XCTAssertEqual(result, .failed)
        XCTAssertFalse(recorder.startCalled, "a recording started after the quit had begun")
        XCTAssertNil(controller.watchLoop)
    }

    func testFinishForQuitStopsAManualRecordingTheControllerHolds() async throws {
        let recorder = makeMockRecorder()
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "quit_controller_manual"),
            permissionHealth: .allHealthy,
            // swiftlint:disable:next trailing_closure
            makeRecorder: { recorder },
        )
        let start = try XCTUnwrap(controller.beginManualRecording(.microphone))
        let result = await start.value
        XCTAssertEqual(result, .started)

        await controller.finishForQuit()

        XCTAssertTrue(recorder.stopCalled)
        XCTAssertNil(controller.watchLoop)
        XCTAssertFalse(controller.hasWorkBeforeQuit)
    }
}
