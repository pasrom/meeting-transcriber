@testable import MeetingTranscriber
import XCTest

/// Cancelling a job whose speaker re-diarization runs late (the naming dialog's
/// "Re-run") must stop that job's work and nothing else.
///
/// The late re-run does not run inside the queue's processing task, so a cancel
/// that reached for that task stopped whichever *other* job the queue was
/// processing at the time, and left the re-run itself going. That re-run then
/// wrote naming data and a `_naming.json` sidecar for a job that no longer
/// existed.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class LateRerunCancelTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "late_rerun_cancel")
    }

    // MARK: - Tests

    /// Job B is mid-transcription while job A's late re-run is cancelled. B is
    /// the only job the queue is processing, so B must not see a cancellation
    /// and must reach its next stage as if nothing had happened.
    func testCancellingALateRerunLeavesTheJobBeingProcessedAlone() async throws {
        let fixture = try await makeJobAwaitingNaming()
        let queue = fixture.queue, engine = fixture.engine, diarizer = fixture.diarizer

        // A goes back to diarizing on its own task and parks there.
        diarizer.parkNextRun()
        queue.completeSpeakerNaming(jobID: fixture.jobA, result: .rerun(2))
        await waitFor { await diarizer.gate.hasWaiter }
        XCTAssertEqual(queue.jobs.first { $0.id == fixture.jobA }?.state, .diarizing, "test premise")

        // B is enqueued and parks inside transcription, under the queue's task.
        engine.parkNextRun()
        let jobB = try makeJob(title: "Job B")
        queue.enqueue(jobB)
        await waitFor(engine.isParked, timeout: .seconds(5))
        XCTAssertEqual(queue.jobs.first { $0.id == jobB.id }?.state, .transcribing, "test premise")

        queue.cancelJob(id: fixture.jobA)
        engine.release()
        await diarizer.gate.open()
        await waitFor(!queue.isProcessing, timeout: .seconds(10))

        XCTAssertFalse(try XCTUnwrap(engine.sawCancellation), "cancelling A cancelled B's run")
        XCTAssertEqual(
            queue.jobs.first { $0.id == jobB.id }?.state, .speakerNamingPending,
            "B stopped mid-stage instead of finishing its run",
        )
        XCTAssertNil(queue.jobs.first { $0.id == fixture.jobA }, "A is gone")
    }

    /// The re-run task belongs to the cancelled job, so it is the one that gets
    /// cancelled.
    func testCancellingALateRerunCancelsItsTask() async throws {
        let fixture = try await makeJobAwaitingNaming()
        let queue = fixture.queue, diarizer = fixture.diarizer

        diarizer.parkNextRun()
        queue.completeSpeakerNaming(jobID: fixture.jobA, result: .rerun(2))
        await waitFor { await diarizer.gate.hasWaiter }

        queue.cancelJob(id: fixture.jobA)
        await diarizer.gate.open()
        await waitFor(diarizer.sawCancellation != nil, timeout: .seconds(5))

        XCTAssertTrue(try XCTUnwrap(diarizer.sawCancellation), "the cancelled job's re-run kept running uncancelled")
    }

    /// Dismissing a job removes it, and a job can be removed while its run is
    /// still going. The run is that job's own work, so it is stopped with it.
    func testRemovingTheJobBeingProcessedCancelsItsRun() async throws {
        let engine = ParkedEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = makeQueue(engine: engine, diarizer: MockDiarization())
        let job = try makeJob(title: "Removed")
        queue.enqueue(job)
        await waitFor(engine.isParked, timeout: .seconds(5))

        queue.removeJob(id: job.id)
        engine.release()
        await waitFor(!queue.isProcessing, timeout: .seconds(10))

        XCTAssertTrue(try XCTUnwrap(engine.sawCancellation), "the removed job's run kept going uncancelled")
    }

    /// A second entry into `processNext` that finds nothing to pick up must not
    /// report the queue idle while the first entry's run is still going, or
    /// the next trigger would start a second run beside it.
    func testAnIdleEntryDoesNotClearProcessingWhileARunIsGoing() async throws {
        let engine = ParkedEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = makeQueue(engine: engine, diarizer: MockDiarization())
        try queue.enqueue(makeJob(title: "Running"))
        await waitFor(engine.isParked, timeout: .seconds(5))

        await queue.processNext()

        XCTAssertTrue(queue.isProcessing, "an idle entry cleared the flag of a run still in flight")
        engine.release()
        await queue.awaitProcessing()
    }

    /// The same holds for an entry that gives up a job because another job is
    /// already running its recording.
    func testGivingUpADuplicateDoesNotClearProcessingWhileARunIsGoing() async throws {
        let engine = ParkedEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = makeQueue(engine: engine, diarizer: MockDiarization())
        let running = try makeJob(title: "Running")
        queue.enqueue(running)
        await waitFor(engine.isParked, timeout: .seconds(5))
        queue.insertJobForTesting(PipelineJob(
            meetingTitle: "Same Audio", appName: "Teams",
            mixPath: running.mixPath, appPath: nil, micPath: nil, micDelay: 0,
        ))

        await queue.processNext()

        XCTAssertTrue(queue.isProcessing, "giving up a duplicate cleared the flag of a run still in flight")
        engine.release()
        await queue.awaitProcessing()
    }

    /// A removed job keeps no protocol-only resume mark.
    func testRemovingAJobForgetsItsProtocolResume() throws {
        let queue = makeQueue(engine: MockEngine(), diarizer: MockDiarization())
        let job = try makeJob(title: "Restored")
        queue.insertJobForTesting(job)
        queue.protocolResumeDispositions[job.id] = .finish

        queue.removeJob(id: job.id)

        XCTAssertNil(queue.protocolResumeDispositions[job.id])
    }

    /// A run entered by awaiting `processNext` directly is not on the queue's
    /// processing task. Cancelling its job still has to reach the task that is
    /// actually running it.
    func testCancellingAJobRunByADirectProcessNextCancelsThatRun() async throws {
        let engine = ParkedEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = makeQueue(engine: engine, diarizer: MockDiarization())
        let job = try makeJob(title: "Direct")
        // Not `enqueue`, which would start the queue's own processing task.
        queue.insertJobForTesting(job)
        let direct = Task { await queue.processNext() }
        await waitFor(engine.isParked, timeout: .seconds(5))

        queue.cancelJob(id: job.id)
        engine.release()
        await direct.value

        XCTAssertTrue(try XCTUnwrap(engine.sawCancellation), "the cancelled job's run kept going uncancelled")
    }

    /// A re-run whose diarizer ignores cancellation still comes back after the
    /// job is gone. It must not bring the job's naming data back, neither in
    /// memory nor as a sidecar on disk.
    func testALateRerunFinishingAfterCancelWritesNoNamingData() async throws {
        let fixture = try await makeJobAwaitingNaming()
        let queue = fixture.queue, diarizer = fixture.diarizer
        XCTAssertFalse(namingSidecars().isEmpty, "test premise: the first run wrote a naming sidecar")

        diarizer.parkNextRun()
        queue.completeSpeakerNaming(jobID: fixture.jobA, result: .rerun(2))
        await waitFor { await diarizer.gate.hasWaiter }
        // Taken before the cancel, which drops them from the session's record.
        let rerun = try XCTUnwrap(queue.naming.lateWork[fixture.jobA]?.values, "test premise: re-run is tracked")

        queue.cancelJob(id: fixture.jobA)
        XCTAssertNil(queue.speakerNamingDataByJob[fixture.jobA], "test premise: cancel dropped the naming data")
        XCTAssertTrue(namingSidecars().isEmpty, "test premise: cancel deleted the naming sidecar")

        await diarizer.gate.open()
        // Run to completion rather than for a fixed time, so a slow runner
        // cannot assert before the re-run had its chance to write.
        for task in rerun {
            await task.value
        }

        XCTAssertNil(queue.speakerNamingDataByJob[fixture.jobA], "re-run recreated naming data for a cancelled job")
        XCTAssertEqual(namingSidecars(), [], "re-run wrote a naming sidecar for a cancelled job")
    }

    /// A cancelled dual-track diarization stops after the app track instead of
    /// diarizing the mic track in full for a job that is gone. Cancelled before
    /// it starts, so the app track runs while the cancellation is already
    /// pending, as it would be if the cancel arrived mid-track.
    func testACancelledDualTrackDiarizationSkipsTheMicTrack() async {
        let queue = PipelineQueue(logDir: tmpDir)
        let diarizer = MockDiarization()
        let tracks = (
            app: tmpDir.appendingPathComponent("app.wav"),
            mic: tmpDir.appendingPathComponent("mic.wav"),
            micDelay: TimeInterval(0),
            viability: DualTrackViability?.none,
        )
        let run = Task {
            try await queue.runDualTrackDiarization(
                diarizeProcess: diarizer, tracks: tracks,
                speakerCount: nil, title: "Cancelled", jobID: UUID(),
            )
        }
        run.cancel()
        let result = await run.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(diarizer.runCount, 1, "the mic track was diarized after the run was cancelled")
    }

    /// A cancellation that arrives while the mic track is diarized ends the
    /// run as cancelled, not as an app-only fallback with a warning about a
    /// mic track that never failed.
    func testACancellationDuringTheMicTrackIsNotTakenForAFailedTrack() async {
        let queue = PipelineQueue(logDir: tmpDir)
        let diarizer = MockDiarization()
        // The mic track's call still returns its result, like a model call
        // that cannot be interrupted, but the cancel arrives during it.
        diarizer.onRun = { run in
            if run == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let tracks = (
            app: tmpDir.appendingPathComponent("app.wav"),
            mic: tmpDir.appendingPathComponent("mic.wav"),
            micDelay: TimeInterval(0),
            viability: DualTrackViability?.none,
        )
        let result = await Task {
            try await queue.runDualTrackDiarization(
                diarizeProcess: diarizer, tracks: tracks,
                speakerCount: nil, title: "Cancelled", jobID: UUID(),
            )
        }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }

    /// A cancelled run is told apart from a failed one by its own task, with
    /// no record kept per job: it ends without an error on anyone, and the
    /// queue moves on to the next job.
    func testACancelledRunEndsQuietlyAndTheQueueMovesOn() async throws {
        let engine = ParkedEngine(parksEveryRun: false)
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = makeQueue(engine: engine, diarizer: MockDiarization())
        var states: [JobState] = []
        queue.onJobStateChange = { _, _, new in states.append(new) }
        engine.parkNextRun()
        let first = try makeJob(title: "Cancelled")
        let second = try makeJob(title: "Next")
        queue.enqueue(first)
        queue.enqueue(second)
        await waitFor(engine.isParked, timeout: .seconds(5))

        queue.cancelJob(id: first.id)
        engine.release()
        await waitFor(
            queue.jobs.first { $0.id == second.id }?.state == .done && !queue.isProcessing,
            timeout: .seconds(10),
        )

        XCTAssertFalse(states.contains(.error), "a cancelled run was reported as a failure: \(states)")
        XCTAssertNil(queue.jobs.first { $0.id == first.id })
        XCTAssertTrue(queue.pipelineRuns.isEmpty, "a finished run is still recorded")
    }

    // MARK: - Fixture

    private struct Fixture {
        let queue: PipelineQueue
        let engine: ParkedEngine
        let diarizer: GatedDiarization
        let jobA: UUID
    }

    /// A queue holding job A at `.speakerNamingPending`, reached by a real run.
    private func makeJobAwaitingNaming() async throws -> Fixture {
        let engine = ParkedEngine(parksEveryRun: false)
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let diarizer = GatedDiarization(result: DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        ))
        let queue = makeQueue(engine: engine, diarizer: diarizer)
        let jobA = try makeJob(title: "Job A")
        queue.enqueue(jobA)
        await waitFor(!queue.isProcessing, timeout: .seconds(10))
        XCTAssertEqual(queue.jobs.first?.state, .speakerNamingPending, "test premise")
        return Fixture(queue: queue, engine: engine, diarizer: diarizer, jobA: jobA.id)
    }

    private func makeQueue(
        engine: any TranscribingEngine, diarizer: any DiarizationProvider,
        protocolGenerator: MockProtocolGen = MockProtocolGen(),
    ) -> PipelineQueue {
        PipelineQueue(
            engine: engine,
            diarizationFactory: { diarizer },
            diarizationFactoryWithMode: nil,
            protocolGeneratorFactory: { protocolGenerator },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: true,
            numSpeakers: 0,
            micLabel: "Me",
            inFlightRuns: InFlightRunRegistry(),
        )
    }

    private func makeJob(title: String) throws -> PipelineJob {
        try PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir),
            appPath: nil, micPath: nil, micDelay: 0,
        )
    }

    private func namingSidecars() -> [String] {
        let all = FileManager.default.enumerator(at: tmpDir, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        return all.filter { $0.hasSuffix(SpeakerNamingStore.namingJSONSuffix) }
    }
}

// MARK: - Test doubles

/// Diarizes immediately, except for the one run after `parkNextRun()`, which
/// waits on `gate`. It ignores cancellation on purpose, like a model call that
/// cannot be interrupted, and only records whether it saw one.
private final class GatedDiarization: DiarizationProvider, @unchecked Sendable {
    let isAvailable = true
    let mode: DiarizerMode = .offline
    let gate = AsyncGate()
    private let result: DiarizationResult
    private let lock = NSLock()
    private var armed = false
    // swiftlint:disable:next discouraged_optional_boolean
    private var cancellation: Bool?

    init(result: DiarizationResult) {
        self.result = result
    }

    // swiftlint:disable:next discouraged_optional_boolean
    var sawCancellation: Bool? {
        lock.withLock { cancellation }
    }

    func parkNextRun() {
        lock.withLock { armed = true }
    }

    func run(audioPath _: URL, numSpeakers _: Int?, meetingTitle _: String) async -> DiarizationResult {
        let shouldPark = lock.withLock { () -> Bool in
            defer { armed = false }
            return armed
        }
        guard shouldPark else { return result }
        await gate.wait()
        let cancelled = Task.isCancelled
        lock.withLock { cancellation = cancelled }
        return result
    }
}
