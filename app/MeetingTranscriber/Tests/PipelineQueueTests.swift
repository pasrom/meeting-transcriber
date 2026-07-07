// swiftlint:disable file_length
@testable import MeetingTranscriber
import os
import XCTest

@MainActor
// swiftlint:disable:next attributes type_body_length balanced_xctest_lifecycle
final class PipelineQueueTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var queue: PipelineQueue!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_queue_test")
        queue = PipelineQueue(logDir: tmpDir)
    }

    private func makeJob(title: String = "Test Meeting") -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }

    func testEnqueueAddsJob() {
        let job = makeJob()
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].meetingTitle, "Test Meeting")
    }

    func testEnqueueMultipleJobs() {
        queue.enqueue(makeJob(title: "Meeting 1"))
        queue.enqueue(makeJob(title: "Meeting 2"))
        XCTAssertEqual(queue.jobs.count, 2)
    }

    func testSnapshotWrittenOnEnqueue() async {
        queue.enqueue(makeJob())
        await queue.awaitSnapshotFlush()
        let snapshotPath = tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath.path))
    }

    func testSnapshotIsValidJSON() async throws {
        queue.enqueue(makeJob(title: "Standup"))
        await queue.awaitSnapshotFlush()
        let snapshotPath = tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        let data = try Data(contentsOf: snapshotPath)
        let jobs = try JSONDecoder().decode([PipelineJob].self, from: data)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].meetingTitle, "Standup")
    }

    func testSaveSnapshotDoesNotBlockMainActor() {
        // Regression guard — if saveSnapshot ever goes synchronous again,
        // a stalled `replaceItemAt` would freeze the UI / RPC / watch loop.
        queue.enqueue(makeJob())
        let start = Date()
        queue.saveSnapshot()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05, "saveSnapshot returned in \(elapsed)s — should be near-instant")
    }

    // MARK: - Terminal job record (durable readback)

    func testTerminalRecordWrittenOnDone() {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let q = PipelineQueue(logDir: tmpDir, terminalJobStore: store)
        var job = makeJob(title: "Synced Call")
        job.transcriptPath = URL(fileURLWithPath: "/out/call.txt")
        job.protocolPath = URL(fileURLWithPath: "/out/call.md")
        q.insertJobForTesting(job)

        q.updateJobState(id: job.id, to: .done)

        let rec = store.lookup(jobID: job.id)
        XCTAssertEqual(rec?.state, .done)
        XCTAssertEqual(rec?.meetingTitle, "Synced Call")
        XCTAssertEqual(rec?.transcriptPath, "/out/call.txt")
        XCTAssertEqual(rec?.protocolPath, "/out/call.md")
    }

    func testTerminalRecordWrittenOnError() {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let q = PipelineQueue(logDir: tmpDir, terminalJobStore: store)
        let job = makeJob()
        q.insertJobForTesting(job)

        q.updateJobState(id: job.id, to: .error, error: "Empty transcript")

        let rec = store.lookup(jobID: job.id)
        XCTAssertEqual(rec?.state, .error)
        XCTAssertEqual(rec?.error, "Empty transcript")
    }

    func testNoTerminalRecordForNonTerminalState() {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let q = PipelineQueue(logDir: tmpDir, terminalJobStore: store)
        let job = makeJob()
        q.insertJobForTesting(job)

        q.updateJobState(id: job.id, to: .transcribing)

        XCTAssertNil(store.lookup(jobID: job.id), "Only terminal states should be recorded")
    }

    func testConsecutiveSnapshotsPersistLastStateOnDisk() async throws {
        // Coalescing: a burst of saves must collapse to a single write of
        // the final state, never an interleaved earlier snapshot.
        for i in 1 ... 5 {
            queue.enqueue(makeJob(title: "Job \(i)"))
        }
        await queue.awaitSnapshotFlush()

        let snapshotPath = tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        let data = try Data(contentsOf: snapshotPath)
        let jobs = try JSONDecoder().decode([PipelineJob].self, from: data)
        XCTAssertEqual(jobs.count, 5)
        XCTAssertEqual(jobs.map(\.meetingTitle), ["Job 1", "Job 2", "Job 3", "Job 4", "Job 5"])
    }

    func testSnapshotWorkerClearsItselfAfterFlush() async {
        // Lifecycle guard: a drained worker must set `snapshotWorker = nil`
        // so the next saveSnapshot starts a fresh task. Without this, a
        // leak-then-skip bug would silently drop later writes.
        queue.enqueue(makeJob())
        XCTAssertTrue(queue.isSnapshotWorkerActive)
        await queue.awaitSnapshotFlush()
        XCTAssertFalse(queue.isSnapshotWorkerActive, "worker should clear itself after the queue drains")

        // Second burst spawns a fresh worker — verifies the first didn't
        // get stuck in a way that prevents re-spawn.
        queue.enqueue(makeJob(title: "Second"))
        XCTAssertTrue(queue.isSnapshotWorkerActive)
        await queue.awaitSnapshotFlush()
        XCTAssertFalse(queue.isSnapshotWorkerActive)
    }

    func testCoalescingReducesActualWriteCount() async {
        // Inject a counting writer to verify the worker collapses many
        // rapid saves into fewer disk writes. testConsecutive... only
        // asserts final state matches — this proves coalescing is real.
        let count = OSAllocatedUnfairLock<Int>(initialState: 0)
        // swiftlint:disable trailing_closure
        let testQueue = PipelineQueue(
            logDir: tmpDir,
            snapshotWriter: { _, _ in count.withLock { $0 += 1 } },
        )
        // swiftlint:enable trailing_closure
        for i in 1 ... 20 {
            testQueue.enqueue(makeJob(title: "Job \(i)"))
        }
        await testQueue.awaitSnapshotFlush()

        let writes = count.withLock { $0 }
        XCTAssertGreaterThan(writes, 0, "writer must be called at least once")
        XCTAssertLessThan(writes, 20, "coalescing should collapse 20 saves to fewer writes (got \(writes))")
    }

    func testSaveSnapshotReturnsImmediatelyWhileWriterIsWedged() async {
        // Direct regression test for the original bug: a stalled writer
        // (modelling `renamex_np` deadlock) must NOT block follow-up
        // saveSnapshot calls on the main actor. With the synchronous-on-
        // main implementation, the second call would hang waiting on the
        // first; with the off-main worker, it returns instantly.
        let gate = DispatchSemaphore(value: 0)
        // swiftlint:disable trailing_closure
        let testQueue = PipelineQueue(
            logDir: tmpDir,
            snapshotWriter: { _, _ in
                gate.wait()
                gate.signal() // re-arm so subsequent callers fall through
            },
        )
        // swiftlint:enable trailing_closure
        testQueue.enqueue(makeJob()) // triggers worker → blocks in writer

        let start = Date()
        testQueue.saveSnapshot() // would deadlock if main-actor were waiting
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05, "saveSnapshot blocked while writer was wedged (\(elapsed)s)")

        gate.signal() // release the wedged write so the worker can drain
        await testQueue.awaitSnapshotFlush()
    }

    func testSnapshotMatchesInMemoryStateAfterStateTransitionBurst() async throws {
        // Pipeline-shaped load: enqueue several jobs, then drive each
        // through transcribing → diarizing → generatingProtocol → done.
        // 12 updateJobState calls + 3 enqueues = 15 saveSnapshot triggers
        // in rapid succession. The on-disk state must match in-memory at
        // the end regardless of how many coalesced batches actually ran.
        let jobs = (1 ... 3).map { makeJob(title: "Job \($0)") }
        for job in jobs {
            queue.enqueue(job)
        }
        let transitions: [JobState] = [.transcribing, .diarizing, .generatingProtocol, .done]
        for job in jobs {
            for next in transitions {
                queue.updateJobState(id: job.id, to: next)
            }
        }
        await queue.awaitSnapshotFlush()

        let snapshotPath = tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        let data = try Data(contentsOf: snapshotPath)
        let onDisk = try JSONDecoder().decode([PipelineJob].self, from: data)
        XCTAssertEqual(onDisk.count, queue.jobs.count)
        XCTAssertEqual(onDisk.map(\.id), queue.jobs.map(\.id))
        XCTAssertEqual(onDisk.map(\.state), queue.jobs.map(\.state))
    }

    func testLogAppendedOnEnqueue() throws {
        queue.enqueue(makeJob())
        let logPath = tmpDir.appendingPathComponent("pipeline_log.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath.path))
        let content = try String(contentsOf: logPath, encoding: .utf8)
        XCTAssertTrue(content.contains("enqueued"))
    }

    // MARK: - updateJobState no-op guard

    /// Count non-empty lines in the pipeline log (one JSON entry per line).
    private func logLineCount(_ url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    func testUpdateJobStateSameStateIsNoOp() throws {
        var job = makeJob()
        job.state = .transcribing
        queue.enqueue(job)

        let logPath = tmpDir.appendingPathComponent("pipeline_log.jsonl")
        let baseline = try logLineCount(logPath)

        var callbackCount = 0
        queue.onJobStateChange = { _, _, _ in callbackCount += 1 }

        queue.updateJobState(id: job.id, to: .transcribing)

        XCTAssertEqual(callbackCount, 0, "same-state update must not fire onJobStateChange")
        XCTAssertEqual(
            try logLineCount(logPath), baseline,
            "same-state update must not append a redundant state_change log line",
        )
    }

    func testUpdateJobStateRealTransitionFiresCallbackOnce() {
        var job = makeJob()
        job.state = .transcribing
        queue.enqueue(job)

        var callbackCount = 0
        var observed: (old: JobState, new: JobState)?
        queue.onJobStateChange = { _, old, new in
            callbackCount += 1
            observed = (old, new)
        }

        queue.updateJobState(id: job.id, to: .diarizing)

        XCTAssertEqual(callbackCount, 1, "a real transition must fire onJobStateChange exactly once")
        XCTAssertEqual(observed?.old, .transcribing)
        XCTAssertEqual(observed?.new, .diarizing)
    }

    func testUpdateJobStateSameStateWithErrorStillApplies() {
        var job = makeJob()
        job.state = .transcribing
        queue.enqueue(job)

        var callbackCount = 0
        queue.onJobStateChange = { _, _, _ in callbackCount += 1 }

        queue.updateJobState(id: job.id, to: .transcribing, error: "boom")

        XCTAssertEqual(
            queue.jobs.first?.error, "boom",
            "a same-state update carrying an error must still persist it",
        )
        XCTAssertEqual(
            callbackCount, 1,
            "an error-bearing update must still notify even when the state is unchanged",
        )
    }

    func testActiveJobs() {
        var job1 = makeJob(title: "Active")
        job1.state = .transcribing
        queue.enqueue(job1)
        queue.enqueue(makeJob(title: "Waiting"))
        XCTAssertEqual(queue.activeJobs.count, 1)
        XCTAssertEqual(queue.activeJobs[0].meetingTitle, "Active")
    }

    func testActiveJobsIncludesDiarizingAndGeneratingProtocol() {
        var j1 = makeJob(title: "Diarizing")
        j1.state = .diarizing
        var j2 = makeJob(title: "Protocol")
        j2.state = .generatingProtocol
        queue.enqueue(j1)
        queue.enqueue(j2)
        XCTAssertEqual(queue.activeJobs.count, 2)
    }

    func testActiveJobsExcludesTerminalStates() {
        var done = makeJob(title: "Done")
        done.state = .done
        var err = makeJob(title: "Error")
        err.state = .error
        queue.enqueue(done)
        queue.enqueue(err)
        queue.enqueue(makeJob(title: "Waiting"))
        XCTAssertTrue(queue.activeJobs.isEmpty)
    }

    func testPendingJobs() {
        queue.enqueue(makeJob(title: "Waiting 1"))
        queue.enqueue(makeJob(title: "Waiting 2"))
        XCTAssertEqual(queue.pendingJobs.count, 2)
    }

    func testRemoveCompletedJob() {
        var job = makeJob()
        job.state = .done
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs.count, 1)
        queue.removeJob(id: job.id)
        XCTAssertEqual(queue.jobs.count, 0)
    }

    // MARK: - Cancel Tests

    func testCancelWaitingJobRemovesIt() {
        let job = makeJob()
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs.count, 1)

        queue.cancelJob(id: job.id)
        XCTAssertEqual(queue.jobs.count, 0)
    }

    func testCancelActiveJobRemovesIt() {
        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .transcribing)

        queue.cancelJob(id: job.id)
        XCTAssertEqual(queue.jobs.count, 0)
    }

    func testCancelDuringSpeakerNamingClearsData() {
        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .diarizing)
        queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Test",
            mapping: [:],
            speakingTimes: [:],
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: false,
        )

        queue.cancelJob(id: job.id)

        XCTAssertNil(queue.pendingSpeakerNaming, "popup data must be cleared on cancel")
        XCTAssertEqual(queue.jobs.count, 0)
    }

    func testCancelActiveJobWithoutPendingNamingIsSafe() {
        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .diarizing)
        XCTAssertNil(queue.pendingSpeakerNaming)

        queue.cancelJob(id: job.id)

        XCTAssertNil(queue.pendingSpeakerNaming)
        XCTAssertEqual(queue.jobs.count, 0)
    }

    func testCancelDoneJobIsNoOp() {
        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        let countBefore = queue.jobs.count
        queue.cancelJob(id: job.id)
        XCTAssertEqual(queue.jobs.count, countBefore)
    }

    // MARK: - Snapshot Recovery Tests (loadSnapshot)

    func testLoadSnapshotRestoresWaitingJobs() throws {
        let mixPath = tmpDir.appendingPathComponent("audio_mix.wav")
        try Data("fake audio".utf8).write(to: mixPath)

        let job = PipelineJob(
            meetingTitle: "Restored Meeting",
            appName: "Teams",
            mixPath: mixPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let data = try JSONEncoder().encode([job])
        let snapshotPath = tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        try data.write(to: snapshotPath)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertEqual(freshQueue.jobs[0].meetingTitle, "Restored Meeting")
        XCTAssertEqual(freshQueue.jobs[0].state, .waiting)
    }

    func testLoadSnapshotResetsActiveToWaiting() throws {
        let mixPath = tmpDir.appendingPathComponent("audio_mix.wav")
        try Data("fake audio".utf8).write(to: mixPath)

        var job = PipelineJob(
            meetingTitle: "Active Meeting",
            appName: "Teams",
            mixPath: mixPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .transcribing
        let data = try JSONEncoder().encode([job])
        try data.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertEqual(freshQueue.jobs[0].state, .waiting)
    }

    func testLoadSnapshotDiscardsDoneJobs() throws {
        let mixPath = tmpDir.appendingPathComponent("audio_mix.wav")
        try Data("fake audio".utf8).write(to: mixPath)

        var job = PipelineJob(
            meetingTitle: "Done Meeting",
            appName: "Teams",
            mixPath: mixPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        let data = try JSONEncoder().encode([job])
        try data.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testLoadSnapshotDiscardsMissingAudio() throws {
        let job = PipelineJob(
            meetingTitle: "Ghost Meeting",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let data = try JSONEncoder().encode([job])
        try data.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testLoadSnapshotNoFileIsNoOp() {
        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()
        XCTAssertTrue(freshQueue.jobs.isEmpty)
    }

    // MARK: - Orphaned Recording Recovery Tests

    func testRecoverFindsUntrackedMixWav() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        await freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)

        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertEqual(freshQueue.jobs[0].meetingTitle, "Recovered Recording (20260311_100000)")
        XCTAssertEqual(
            freshQueue.jobs[0].mixPath?.standardizedFileURL,
            mixFile.standardizedFileURL,
        )
    }

    func testRecoverSkipsTrackedFiles() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        let existing = PipelineJob(
            meetingTitle: "Already Tracked",
            appName: "Teams",
            mixPath: mixFile,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        freshQueue.enqueue(existing)

        await freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertEqual(freshQueue.jobs[0].meetingTitle, "Already Tracked")
    }

    func testRecoverSkipsTinyFiles() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data(repeating: 0x00, count: 44).write(to: mixFile)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        await freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)

        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testRecoverFindsCompanionTracks() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let prefix = "20260311_100000"
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("\(prefix)_mix.wav"))
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("\(prefix)_app.wav"))
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("\(prefix)_mic.wav"))

        let freshQueue = PipelineQueue(logDir: tmpDir)
        await freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)

        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertNotNil(freshQueue.jobs[0].appPath)
        XCTAssertNotNil(freshQueue.jobs[0].micPath)
    }

    func testRecoverSkipsOldFiles() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20250101_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        await freshQueue.recoverOrphanedRecordings(recordingsDir: recDir, maxAge: 0)

        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testRecoverSkipsProcessedFiles() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        // Mark it as already processed
        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.processedLedger.markProcessed(mixPath: mixFile)

        await freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testErrorJobIsMarkedProcessedSoRecoverySkipsIt() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let mixFile = recDir.appendingPathComponent("20260318_214744_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        // Enqueue and fail the job (simulates "Empty transcript" scenario)
        let job = PipelineJob(
            meetingTitle: "Brave Browser",
            appName: "Brave Browser",
            mixPath: mixFile,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Empty transcript")

        // A fresh queue (simulates pressing Start Watching) must not recover the failed recording
        let freshQueue = PipelineQueue(logDir: tmpDir)
        await freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertTrue(freshQueue.jobs.isEmpty, "Failed recording should not be re-queued")
    }

    func testRecoverEmptyDirIsNoOp() async {
        let recDir = tmpDir.appendingPathComponent("nonexistent_recordings")
        let freshQueue = PipelineQueue(logDir: tmpDir)
        await freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertTrue(freshQueue.jobs.isEmpty)
    }

    func testRecoverRunsDirScanOffMainActor() async throws {
        // Smoke test that the scan doesn't starve main-actor work: kick
        // off recovery with `async let`, do synchronous work concurrently,
        // verify both complete.
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        for i in 0 ..< 50 {
            let mixFile = recDir.appendingPathComponent("20260311_10000\(i)_mix.wav")
            try Data(repeating: 0xFF, count: 100).write(to: mixFile)
        }

        let freshQueue = PipelineQueue(logDir: tmpDir)
        async let recovery: Void = freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)

        var counter = 0
        for _ in 0 ..< 10000 {
            counter += 1
        }
        XCTAssertEqual(counter, 10000)

        await recovery
        XCTAssertEqual(freshQueue.jobs.count, 50)
    }

    // MARK: - Processing Tests

    private func makeProcessingQueue() -> PipelineQueue {
        PipelineQueue(
            engine: WhisperKitEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: false,
            micLabel: "Me",
        )
    }

    func testProcessNextPicksFirstWaitingJob() async {
        let pQueue = makeProcessingQueue()

        let job = makeJob()
        pQueue.enqueue(job)
        XCTAssertEqual(pQueue.jobs[0].state, .waiting)

        await pQueue.processNext()

        // Job should have been picked up (state != waiting)
        XCTAssertNotEqual(pQueue.jobs[0].state, .waiting)
    }

    func testProcessNextSkipsWhenNoWaitingJobs() async {
        let pQueue = makeProcessingQueue()
        await pQueue.processNext()
        XCTAssertTrue(pQueue.jobs.isEmpty)
    }

    func testAwaitProcessingReturnsImmediatelyWhenIdle() async {
        let pQueue = makeProcessingQueue()
        await pQueue.awaitProcessing()
        XCTAssertFalse(pQueue.isProcessing)
        XCTAssertTrue(pQueue.pendingJobs.isEmpty)
    }

    func testAwaitProcessingDrainsSpawnedTask() async {
        let pQueue = makeProcessingQueue()
        let job = makeJob()
        pQueue.enqueue(job)
        // Spawned task is in flight (or about to be). Without awaitProcessing,
        // observers race against the spawned Task.
        await pQueue.awaitProcessing()
        XCTAssertFalse(pQueue.isProcessing, "queue should be idle after awaitProcessing")
        XCTAssertTrue(pQueue.pendingJobs.isEmpty, "no jobs should remain in waiting")
        XCTAssertNotEqual(pQueue.jobs.first?.state, .waiting)
    }

    func testIsProcessingFlag() {
        let pQueue = makeProcessingQueue()
        XCTAssertFalse(pQueue.isProcessing)
    }

    // MARK: - Auto-Removal Tests

    func testCompletedJobAutoRemovedAfterDelay() async throws {
        let queue = PipelineQueue(logDir: tmpDir, completedJobLifetime: 0.2)
        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)
        XCTAssertEqual(queue.jobs.count, 1)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(queue.jobs.count, 0, "Done job should be auto-removed")
    }

    func testErrorJobNotAutoRemoved() async throws {
        let queue = PipelineQueue(logDir: tmpDir, completedJobLifetime: 0.2)
        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Test error")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(queue.jobs.count, 1, "Error job should NOT be auto-removed")
    }

    // MARK: - Mock-Engine Processing Tests

    private func makeMockProcessingQueue(
        engine: MockEngine? = nil,
        diarizationFactory: @escaping () -> any DiarizationProvider = { MockDiarization() },
        diarizationFactoryWithMode: ((DiarizerMode) -> any DiarizationProvider)? = nil,
        diarizeEnabled: Bool = false,
        numSpeakers: Int = 0,
    ) -> (PipelineQueue, MockEngine) {
        let engine = engine ?? MockEngine()
        let q = PipelineQueue(
            engine: engine,
            diarizationFactory: diarizationFactory,
            diarizationFactoryWithMode: diarizationFactoryWithMode,
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: diarizeEnabled,
            numSpeakers: numSpeakers,
            micLabel: "Me",
        )
        return (q, engine)
    }

    func testProcessNextWithMockEngineTranscribes() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello from mock"),
        ]
        let (pQueue, _) = makeMockProcessingQueue(engine: engine)

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Mock Test",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()

        XCTAssertTrue(engine.transcribeCallCount > 0)
    }

    func testProcessNextEmptyTranscriptSetsError() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [] // empty = no speech
        let (pQueue, _) = makeMockProcessingQueue(engine: engine)

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Silent Meeting",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()

        XCTAssertEqual(pQueue.jobs.first?.state, .error)
        XCTAssertEqual(pQueue.jobs.first?.error, "Empty transcript")
    }

    func testProcessNextDualSourceTranscribesBothTracks() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Track content"),
        ]
        let (pQueue, _) = makeMockProcessingQueue(engine: engine)

        try pQueue.enqueue(makeDualSourceJob(title: "Dual Source"))
        await pQueue.processNext()

        // Dual source: transcribes app + mic = 2 calls
        XCTAssertEqual(engine.transcribeCallCount, 2)
    }

    // MARK: - diarize() assign-phase characterization

    //
    // These pin the final speaker-labeled transcript that diarize() hands to
    // protocol generation, for each of its three assignment topologies
    // (single-source / dual-track-both / dual-track-mic-fail). They guard the
    // extraction of the assignment logic into DiarizationProcess: the
    // observable output must stay identical across the refactor. `embeddings:
    // nil` short-circuits the matcher + naming dialog so the job flows straight
    // through to the assignment branch.

    private func makeCapturingQueue(
        engine: MockEngine,
        diar: MockDiarization,
        protocolGen: MockProtocolGen,
        micLabel: String = "Me",
    ) -> PipelineQueue {
        PipelineQueue(
            engine: engine,
            diarizationFactory: { diar },
            diarizationFactoryWithMode: nil,
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: true,
            numSpeakers: 0,
            micLabel: micLabel,
        )
    }

    private func makeDualSourceJob(title: String, micDelay: TimeInterval = 0) throws -> PipelineJob {
        let audioPath = try createTestAudioFile(in: tmpDir)
        let appPath = tmpDir.appendingPathComponent("app_audio.wav")
        let micPath = tmpDir.appendingPathComponent("mic_audio.wav")
        try? FileManager.default.removeItem(at: appPath)
        try? FileManager.default.removeItem(at: micPath)
        try FileManager.default.copyItem(at: audioPath, to: appPath)
        try FileManager.default.copyItem(at: audioPath, to: micPath)
        return PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: audioPath, appPath: appPath, micPath: micPath, micDelay: micDelay,
        )
    }

    /// Drive a single-source job through the pipeline to `.speakerNamingPending`
    /// with a one-speaker initial diarization, returning the queue, the mock
    /// diarizer (set `resultToReturn` to a multi-speaker result for the re-run),
    /// and the job id. Shared setup for the late-rerun re-segmentation tests.
    private func makeSingleSourceJobAtNamingPending(
        title: String, transcriptSegments: [TimestampedSegment],
    ) async throws -> (PipelineQueue, MockDiarization, UUID) {
        let engine = MockEngine()
        engine.segmentsToReturn = transcriptSegments
        let mockDiar = MockDiarization()
        let span = transcriptSegments.last?.end ?? 0
        // Initial diarization collapses everything onto one speaker.
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: transcriptSegments.first?.start ?? 0, end: span, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": span],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine, diarizationFactory: { mockDiar }, diarizeEnabled: true,
        )
        let job = try PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        let pending = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending { pending.fulfill() }
        }
        await pQueue.processNext()
        await fulfillment(of: [pending], timeout: 10)
        return (pQueue, mockDiar, job.id)
    }

    func testDiarizeSingleSourceLabelsTranscriptWithAutoNames() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        let diar = MockDiarization()
        diar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: ["SPEAKER_0": "Alice"],
            embeddings: nil,
        )
        let protocolGen = MockProtocolGen()
        let q = makeCapturingQueue(engine: engine, diar: diar, protocolGen: protocolGen)

        let audioPath = try createTestAudioFile(in: tmpDir)
        q.enqueue(PipelineJob(
            meetingTitle: "Single", appName: "Teams",
            mixPath: audioPath, appPath: nil, micPath: nil, micDelay: 0,
        ))
        await q.processNext()

        let transcript = try XCTUnwrap(protocolGen.capturedTranscript)
        XCTAssertTrue(
            transcript.contains("Alice: Hello world"),
            "single-source: SPEAKER_0 should map to Alice — got: \(transcript)",
        )
    }

    /// An engine that doesn't produce per-utterance timestamps (emitting one
    /// segment for the whole recording) must skip diarization entirely — running
    /// it would collapse the meeting onto a single speaker — and warn the user.
    func testDiarizeSkippedWhenEngineLacksTimestamps() async throws {
        let engine = MockEngine()
        engine.providesTimestamps = false
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 30, text: "Whole meeting in one segment")]
        let diar = MockDiarization()
        let protocolGen = MockProtocolGen()
        let q = makeCapturingQueue(engine: engine, diar: diar, protocolGen: protocolGen)

        let audioPath = try createTestAudioFile(in: tmpDir)
        q.enqueue(PipelineJob(
            meetingTitle: "NoTimestamps", appName: "Teams",
            mixPath: audioPath, appPath: nil, micPath: nil, micDelay: 0,
        ))
        await q.processNext()

        XCTAssertEqual(diar.runCount, 0, "diarization must not run for a timestamp-less engine")
        let transcript = try XCTUnwrap(protocolGen.capturedTranscript)
        XCTAssertTrue(
            transcript.contains("Whole meeting in one segment"),
            "transcript should pass through unlabeled — got: \(transcript)",
        )
        let warnings = q.jobs.first?.warnings ?? []
        XCTAssertTrue(
            warnings.contains { $0.contains("per-utterance timestamps") },
            "expected a timestamp-capability warning — got: \(warnings)",
        )
    }

    func testDiarizeDualTrackLabelsBothTracks() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let diar = MockDiarization()
        diar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: ["SPEAKER_0": "Alice"],
            embeddings: nil,
        )
        let protocolGen = MockProtocolGen()
        let q = makeCapturingQueue(engine: engine, diar: diar, protocolGen: protocolGen)

        try q.enqueue(makeDualSourceJob(title: "Dual"))
        await q.processNext()

        let transcript = try XCTUnwrap(protocolGen.capturedTranscript)
        // Both tracks' segments are assigned via their (R_/M_-unprefixed) diarization → Alice.
        XCTAssertTrue(transcript.contains("Alice:"), "dual-track: speakers should be named — got: \(transcript)")
        XCTAssertFalse(transcript.contains("Remote:"), "dual-track: raw 'Remote' app label should be replaced")
        XCTAssertFalse(
            transcript.contains("] Me:"),
            "dual-track: raw 'Me' mic label should be replaced when mic diarization succeeds — got: \(transcript)",
        )
    }

    func testDiarizeDualTrackMicFailKeepsRawMicLabel() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let diar = MockDiarization()
        diar.throwOnPathSuffix = "mic_16k.wav" // mic diarization fails → app-only fallback
        diar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: ["SPEAKER_0": "Alice"],
            embeddings: nil,
        )
        let protocolGen = MockProtocolGen()
        let q = makeCapturingQueue(engine: engine, diar: diar, protocolGen: protocolGen)

        try q.enqueue(makeDualSourceJob(title: "Dual MicFail"))
        await q.processNext()

        let transcript = try XCTUnwrap(protocolGen.capturedTranscript)
        // App-only fallback: mic segments keep their raw 'Me' label (not force-matched).
        XCTAssertTrue(
            transcript.contains("] Me:"),
            "mic-fail fallback: mic segments keep raw mic label — got: \(transcript)",
        )
        // The app track is still diarized + named: its segment gets the matched
        // name "Alice", not the raw diarizer ID and not the pre-assignment
        // "Remote" tag. (This is the bug fix — the app-only fallback used to
        // drop app-track names by unprefixing already-unprefixed keys.)
        XCTAssertTrue(
            transcript.contains("Alice:"),
            "mic-fail fallback: app segments keep their matched name — got: \(transcript)",
        )
        XCTAssertFalse(
            transcript.contains("SPEAKER_0:"),
            "mic-fail fallback: app segments must not surface the raw diarizer ID — got: \(transcript)",
        )
        XCTAssertFalse(
            transcript.contains("Remote:"),
            "mic-fail fallback: app segments must lose their raw 'Remote' tag — got: \(transcript)",
        )
        let warnings = try XCTUnwrap(q.jobs.first?.warnings)
        XCTAssertTrue(
            warnings.contains { $0.contains("Mic track diarization failed") },
            "mic-fail fallback should add a warning — got: \(warnings)",
        )
    }

    /// Dual-track diarization must shift the mic track's diarization by
    /// `micDelay` so it lands on the same (app/canonical) timeline as the mic
    /// transcript segments — which `mergeDualSourceSegments` already shifted by
    /// `+micDelay`. Without the shift, the diarization and transcript are offset
    /// by `micDelay` and `assignSpeakers` overlaps the wrong diarization segment,
    /// mislabeling mic-side speakers (only visible with ≥2 mic speakers; a single
    /// mic speaker is masked by the nearest-gap fallback).
    func testDiarizeDualTrackShiftsMicDiarizationByMicDelay() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "MICWORD")]
        let diar = MockDiarization()
        // Mic-timeline diarization: the utterance's true speaker is SPEAKER_0
        // (Bob), who speaks at raw [0,5]. SPEAKER_1 (Carol) speaks later at
        // [100,105]. The pipeline shifts the mic transcript by +micDelay (100s)
        // to [100,105]; the mic diarization must be shifted to match, else
        // [100,105] overlaps SPEAKER_1 and the utterance is mislabeled Carol.
        diar.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 100, end: 105, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            autoNames: ["SPEAKER_0": "Bob", "SPEAKER_1": "Carol"],
            embeddings: nil,
        )
        let protocolGen = MockProtocolGen()
        let q = makeCapturingQueue(engine: engine, diar: diar, protocolGen: protocolGen)

        try q.enqueue(makeDualSourceJob(title: "MicDelay", micDelay: 100))
        await q.processNext()

        let transcript = try XCTUnwrap(protocolGen.capturedTranscript)
        // The mic utterance's true speaker is Bob; Carol only surfaces if the
        // mic diarization wasn't shifted to match the +micDelay transcript shift.
        XCTAssertFalse(
            transcript.contains("Carol"),
            "mic diarization must be shifted by micDelay to align with the shifted mic transcript — got: \(transcript)",
        )
        XCTAssertTrue(transcript.contains("Bob"), "mic utterance should be labeled Bob — got: \(transcript)")
    }

    /// A user can set the Mic Speaker Name to "Remote" — the same literal used
    /// as the reserved app/remote routing tag (`DiarizationProcess.remoteSpeakerLabel`).
    /// Without sanitization, `mergeDualSourceSegments` tags both tracks "Remote"
    /// and `labelSegments`' per-track filters both match every segment, so each
    /// utterance is emitted once per track filter → app audio double-counted.
    /// PipelineQueue must fall the colliding mic label back to a distinct one.
    func testDiarizeDualTrackMicLabelRemoteDoesNotDoubleCount() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "ZZWORD")]
        let diar = MockDiarization()
        // Both tracks diarize successfully (no mic-fail) → dual-track topology.
        diar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: nil,
        )
        let protocolGen = MockProtocolGen()
        let q = makeCapturingQueue(engine: engine, diar: diar, protocolGen: protocolGen, micLabel: "Remote")

        try q.enqueue(makeDualSourceJob(title: "Remote MicLabel"))
        await q.processNext()

        let transcript = try XCTUnwrap(protocolGen.capturedTranscript)
        // Dual-source mock transcribes both tracks → "ZZWORD" twice (once per
        // real track). The double-count bug routes every segment through BOTH
        // filters → four. Pin two.
        let occurrences = transcript.components(separatedBy: "ZZWORD").count - 1
        XCTAssertEqual(
            occurrences, 2,
            "app/mic audio must not be double-counted when micName == 'Remote' — got: \(transcript)",
        )
    }

    func testSpeakerNamingHandlerCalled() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]
        let mockDiar = MockDiarization()
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        var handlerCalled = false
        pQueue.speakerNamingHandler = { _ in
            handlerCalled = true
            return .skipped
        }

        // The handler now runs after the job reaches `.speakerNamingPending`
        // (the production flow), in a detached Task that outlives
        // `processNext()`, so wait for the terminal state before asserting.
        let done = XCTestExpectation(description: "job reaches done")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { done.fulfill() }
        }

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Naming Test",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()
        await fulfillment(of: [done], timeout: 10)

        XCTAssertTrue(handlerCalled)
    }

    func testSpeakerNamingSkippedUsesAutoNames() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]
        let mockDiar = MockDiarization()
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        pQueue.speakerNamingHandler = { _ in .skipped }

        let done = XCTestExpectation(description: "job reaches a terminal state")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done || newState == .error { done.fulfill() }
        }

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Skip Test",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()
        await fulfillment(of: [done], timeout: 10)

        // Should complete without error (auto names used)
        let finalState = pQueue.jobs.first?.state
        XCTAssertTrue(finalState == .done || finalState == .error)
    }

    func testSpeakerNamingRerunCallsDiarizationAgain() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]
        let mockDiar = MockDiarization()
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        var callCount = 0
        pQueue.speakerNamingHandler = { _ in
            callCount += 1
            if callCount == 1 {
                return .rerun(3)
            }
            return .skipped
        }

        // First handler call (`.rerun`) drives a late re-diarization; the second
        // (`.skipped`) finishes the job. All of that runs in detached Tasks after
        // `processNext()` returns, so wait for the terminal state.
        let done = XCTestExpectation(description: "job done after rerun")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { done.fulfill() }
        }

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Rerun Test",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()
        await fulfillment(of: [done], timeout: 60)

        // Handler should be called twice (first returns rerun, second returns skipped)
        XCTAssertEqual(callCount, 2)
        // The re-run must actually re-diarize with the new speaker count: first
        // run uses the default (nil → auto), second uses the rerun's count (3).
        XCTAssertEqual(mockDiar.runCount, 2)
        XCTAssertEqual(mockDiar.receivedNumSpeakers, [nil, 3])
    }

    /// The batch pipeline reaches `.speakerNamingPending`, then the injected
    /// naming handler returns `.rerunWithMode`. The mode override must be
    /// honoured end-to-end: routed through the mode-aware factory and written
    /// back onto the job's `usedDiarizerMode`. The now-deleted in-line handler
    /// path silently downgraded this to a same-mode re-run and had zero
    /// coverage; converging both paths onto `completeSpeakerNaming` fixes it.
    func testSpeakerNamingRerunWithModeThroughHandlerHonorsMode() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let offlineDiar = makeModeOverrideDiar(.offline)
        let sortformerDiar = makeModeOverrideDiar(.sortformer)
        let modeOverrideCalls = OSAllocatedUnfairLock<[DiarizerMode]>(initialState: [])
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { offlineDiar },
            diarizationFactoryWithMode: { mode in
                modeOverrideCalls.withLock { $0.append(mode) }
                return mode == .sortformer ? sortformerDiar : offlineDiar
            },
            diarizeEnabled: true,
        )

        var callCount = 0
        pQueue.speakerNamingHandler = { _ in
            callCount += 1
            // First presentation: ask to re-run in Sortformer mode. Second
            // presentation (after the mode-override re-diarization): accept.
            return callCount == 1 ? .rerunWithMode(.sortformer, 4) : .confirmed([:])
        }

        let done = XCTestExpectation(description: "job done after mode-override rerun")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { done.fulfill() }
        }

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Handler Mode Override", appName: "TestApp",
            mixPath: audioPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()
        await fulfillment(of: [done], timeout: 60)

        XCTAssertEqual(callCount, 2, "handler is re-invoked after the mode-override re-diarization")
        XCTAssertEqual(
            modeOverrideCalls.withLock(\.self), [.sortformer],
            "the handler's mode override must route through the mode-aware factory",
        )
        XCTAssertEqual(
            pQueue.jobs.first?.usedDiarizerMode, .sortformer,
            "the honoured mode must be recorded on the job",
        )
        XCTAssertEqual(pQueue.jobs.first?.state, .done)
    }

    func testCompleteSpeakerNamingDoubleResumeIsNoOp() {
        // completeSpeakerNaming should not crash when called twice
        let queue = PipelineQueue(logDir: tmpDir)
        queue.completeSpeakerNaming(result: .skipped)
        queue.completeSpeakerNaming(result: .skipped) // should not crash
    }

    func testOnJobStateChangeCallbackFired() {
        var transitions: [(UUID, JobState, JobState)] = []
        queue.onJobStateChange = { job, old, new in
            transitions.append((job.id, old, new))
        }

        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .transcribing)

        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions[0].1, .waiting)
        XCTAssertEqual(transitions[0].2, .transcribing)
    }

    func testLoadSnapshotResetsDiarizingToWaiting() throws {
        let mixPath = tmpDir.appendingPathComponent("audio_diar.wav")
        try Data("fake audio".utf8).write(to: mixPath)

        var job = PipelineJob(
            meetingTitle: "Diarizing Meeting",
            appName: "Teams",
            mixPath: mixPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .diarizing
        let data = try JSONEncoder().encode([job])
        try data.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertEqual(freshQueue.jobs[0].state, .waiting)
    }

    func testLoadSnapshotResetsGeneratingProtocolToWaiting() throws {
        let mixPath = tmpDir.appendingPathComponent("audio_proto.wav")
        try Data("fake audio".utf8).write(to: mixPath)

        var job = PipelineJob(
            meetingTitle: "Protocol Meeting",
            appName: "Teams",
            mixPath: mixPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .generatingProtocol
        let data = try JSONEncoder().encode([job])
        try data.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertEqual(freshQueue.jobs[0].state, .waiting)
    }

    // MARK: - addWarning

    func testAddWarningAppendsToJob() {
        let queue = PipelineQueue(logDir: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Warn Test",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.addWarning(id: job.id, "Test warning")
        XCTAssertEqual(queue.jobs[0].warnings, ["Test warning"])
    }

    func testAddWarningDeduplicates() {
        let queue = PipelineQueue(logDir: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Dedup Test",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.addWarning(id: job.id, "Same warning")
        queue.addWarning(id: job.id, "Same warning")
        XCTAssertEqual(queue.jobs[0].warnings.count, 1)
    }

    func testAddWarningIgnoresInvalidJobID() {
        let queue = PipelineQueue(logDir: tmpDir)
        // Should not crash with non-existent job ID
        queue.addWarning(id: UUID(), "Orphan warning")
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testAddWarningMultipleDistinct() {
        let queue = PipelineQueue(logDir: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Multi Test",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.addWarning(id: job.id, "Warning A")
        queue.addWarning(id: job.id, "Warning B")
        XCTAssertEqual(queue.jobs[0].warnings, ["Warning A", "Warning B"])
    }

    // MARK: - State Machine Edge Cases

    func testCompletedJobsFilter() {
        var doneJob = makeJob(title: "Done Meeting")
        doneJob.state = .done
        queue.enqueue(doneJob)
        queue.enqueue(makeJob(title: "Waiting Meeting"))

        XCTAssertEqual(queue.completedJobs.count, 1)
        XCTAssertEqual(queue.completedJobs[0].meetingTitle, "Done Meeting")
    }

    func testCancelNonexistentJobIsNoOp() {
        queue.enqueue(makeJob())
        let countBefore = queue.jobs.count
        queue.cancelJob(id: UUID())
        XCTAssertEqual(queue.jobs.count, countBefore)
    }

    func testUpdateJobStateNonexistentJobIsNoOp() {
        queue.enqueue(makeJob())
        let countBefore = queue.jobs.count
        queue.updateJobState(id: UUID(), to: .transcribing)
        XCTAssertEqual(queue.jobs.count, countBefore)
        // All existing jobs should remain in their original state
        XCTAssertEqual(queue.jobs[0].state, .waiting)
    }

    func testUpdateJobStateSetsError() {
        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Something went wrong")

        XCTAssertEqual(queue.jobs[0].state, .error)
        XCTAssertEqual(queue.jobs[0].error, "Something went wrong")
    }

    func testLoadSnapshotCorruptJSONIsNoOp() throws {
        let snapshotPath = tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        try Data("{{not valid json".utf8).write(to: snapshotPath)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        XCTAssertTrue(freshQueue.jobs.isEmpty)
    }

    // MARK: - Crash-Recovery E2E

    func testCrashRecoveryResumesAndCompletesJob() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Recovery test"),
        ]
        let protocolGen = MockProtocolGen()
        let audioPath = try createTestAudioFile(in: tmpDir)

        let queue1 = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
        )

        let job = PipelineJob(
            meetingTitle: "Crash Test",
            appName: "Test",
            mixPath: audioPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue1.enqueue(job)
        queue1.updateJobState(id: job.id, to: .transcribing)
        queue1.saveSnapshot()
        await queue1.awaitSnapshotFlush()

        let snapshotPath = tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath.path))

        // "Crash" — create fresh queue from snapshot
        let engine2 = MockEngine()
        engine2.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Recovery works"),
        ]
        let protocolGen2 = MockProtocolGen()

        let queue2 = PipelineQueue(
            engine: engine2,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen2 },
            outputDir: tmpDir,
            logDir: tmpDir,
        )

        queue2.loadSnapshot()
        XCTAssertEqual(queue2.jobs.count, 1)
        XCTAssertEqual(queue2.jobs.first?.state, .waiting)
        XCTAssertEqual(queue2.jobs.first?.meetingTitle, "Crash Test")

        await queue2.processNext()

        XCTAssertEqual(queue2.jobs.first?.state, .done)
        XCTAssertEqual(engine2.transcribeCallCount, 1)
        XCTAssertTrue(protocolGen2.generateCalled)
        XCTAssertNotNil(queue2.jobs.first?.protocolPath)
    }

    func testCrashRecoveryDuringDiarizingResumes() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Diarize recovery"),
        ]
        let audioPath = try createTestAudioFile(in: tmpDir)

        let queue1 = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: true,
        )

        let job = PipelineJob(
            meetingTitle: "Diarize Crash",
            appName: "Test",
            mixPath: audioPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue1.enqueue(job)
        queue1.updateJobState(id: job.id, to: .diarizing)
        queue1.saveSnapshot()
        await queue1.awaitSnapshotFlush()

        let engine2 = MockEngine()
        engine2.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Recovered"),
        ]
        let protocolGen2 = MockProtocolGen()

        let queue2 = PipelineQueue(
            engine: engine2,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen2 },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: true,
        )
        queue2.speakerNamingHandler = { _ in .skipped }

        queue2.loadSnapshot()
        XCTAssertEqual(queue2.jobs.first?.state, .waiting)

        await queue2.processNext()
        XCTAssertEqual(queue2.jobs.first?.state, .done)
    }

    func testJobStateSpeakerNamingPendingLabel() {
        XCTAssertEqual(JobState.speakerNamingPending.label, "Name Speakers...")
    }

    func testJobStateSpeakerNamingPendingIsCodable() throws {
        let state = JobState.speakerNamingPending
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(JobState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    // MARK: - SpeakerNamingData Codable

    func testSpeakerNamingDataRoundTripsThroughJSON() throws {
        let data = PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: "Test Meeting",
            mapping: ["SPEAKER_0": "Alice", "SPEAKER_1": "Speaker C"],
            speakingTimes: ["SPEAKER_0": 120.5, "SPEAKER_1": 85.3],
            embeddings: ["SPEAKER_0": [0.1, 0.2], "SPEAKER_1": [0.3, 0.4]],
            audioPath: URL(fileURLWithPath: "/tmp/test_16k.wav"),
            segments: [
                .init(start: 0.0, end: 5.0, speaker: "SPEAKER_0"),
                .init(start: 5.0, end: 10.0, speaker: "SPEAKER_1"),
            ],
            participants: ["Alice", "Speaker C", "Speaker D"],
            isDualSource: false,
        )

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(PipelineQueue.SpeakerNamingData.self, from: encoded)

        XCTAssertEqual(decoded.jobID, data.jobID)
        XCTAssertEqual(decoded.meetingTitle, data.meetingTitle)
        XCTAssertEqual(decoded.mapping, data.mapping)
        XCTAssertEqual(decoded.participants, data.participants)
        XCTAssertFalse(decoded.isDualSource)
        XCTAssertEqual(decoded.segments.count, 2)
    }

    /// Regression: each `SpeakerNamingData` instance must carry a unique
    /// `revision` so that SwiftUI `.onChange(of: data.revision)` fires on
    /// every late-diarization re-render — even when the resulting mapping
    /// happens to be byte-identical to the previous run. Without this,
    /// the SpeakerNamingView's per-presentation `@State` reset never runs
    /// and consecutive Re-run clicks are silently swallowed.
    func test_speakerNamingData_revisionDiffersBetweenInstancesWithIdenticalContent() {
        let jobID = UUID()
        let mapping = ["SPEAKER_0": "Alice"]
        let speakingTimes: [String: TimeInterval] = ["SPEAKER_0": 60]
        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.1, 0.2]]

        let first = PipelineQueue.SpeakerNamingData(
            jobID: jobID, meetingTitle: "Standup",
            mapping: mapping, speakingTimes: speakingTimes,
            embeddings: embeddings, audioPath: nil,
            segments: [], participants: [], isDualSource: false,
        )
        let second = PipelineQueue.SpeakerNamingData(
            jobID: jobID, meetingTitle: "Standup",
            mapping: mapping, speakingTimes: speakingTimes,
            embeddings: embeddings, audioPath: nil,
            segments: [], participants: [], isDualSource: false,
        )

        XCTAssertNotEqual(first.revision, second.revision)
    }

    /// `revision` is a presentation-only marker and must not survive the
    /// JSON sidecar round-trip — encoding leaves it out, decoding regenerates
    /// it. Otherwise reloading the sidecar from disk would freeze the
    /// revision and re-introduce the stuck-button bug after app restart.
    func test_speakerNamingData_revisionRegeneratesOnJSONRoundTrip() throws {
        let original = PipelineQueue.SpeakerNamingData(
            jobID: UUID(), meetingTitle: "Standup",
            mapping: ["S": "Alice"], speakingTimes: ["S": 60],
            embeddings: ["S": [0.1]], audioPath: nil,
            segments: [], participants: [], isDualSource: false,
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PipelineQueue.SpeakerNamingData.self, from: encoded)

        XCTAssertNotEqual(original.revision, decoded.revision)
        // JSON payload must not contain the field name.
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("revision"))
    }

    func testPendingSpeakerNamingJobsReturnsNamingPendingJobs() {
        let queue = PipelineQueue(logDir: tmpDir)
        XCTAssertTrue(queue.pendingSpeakerNamingJobs.isEmpty)
    }

    // MARK: - Pipeline Timeout → speakerNamingPending

    func testPipelineSetsSpeakerNamingPendingAfterTimeout() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]
        let mockDiar = MockDiarization()
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )
        // Don't set speakerNamingHandler — pipeline proceeds with auto-names immediately

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Timeout Test",
            appName: "TestApp",
            mixPath: audioPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        pQueue.enqueue(job)

        let expectation = XCTestExpectation(description: "Pipeline completes")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending {
                expectation.fulfill()
            }
        }

        await pQueue.processNext()

        await fulfillment(of: [expectation], timeout: 10)

        let finalJob = pQueue.jobs.first
        XCTAssertEqual(
            finalJob?.state, .speakerNamingPending,
            "Job should be speakerNamingPending when naming was not confirmed",
        )
        XCTAssertNotNil(
            pQueue.speakerNamingDataByJob[job.id],
            "Naming data should still be available",
        )
    }

    func testPipelineSetsDoneWhenNamingConfirmed() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]
        let mockDiar = MockDiarization()
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        pQueue.speakerNamingHandler = { _ in .confirmed(["SPEAKER_0": "Alice"]) }

        // Confirm runs after `.speakerNamingPending`, in a detached Task that
        // outlives `processNext()`, so wait for the terminal state.
        let done = XCTestExpectation(description: "job done after confirm")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { done.fulfill() }
        }

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Confirm Test",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()
        await fulfillment(of: [done], timeout: 60)

        let finalState = pQueue.jobs.first?.state
        XCTAssertEqual(finalState, .done, "Confirmed naming should end as .done")
    }

    func testPipelineAutoSkipsNamingForHeadlessJob() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]
        let mockDiar = MockDiarization()
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )
        // No speakerNamingHandler — the production/headless path. autoSkipNaming
        // must make the job finish on its own instead of parking at
        // .speakerNamingPending (which would wedge a headless blocking call).

        let audioPath = try createTestAudioFile(in: tmpDir)
        var job = PipelineJob(
            meetingTitle: "Headless Test",
            appName: "TestApp",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.autoSkipNaming = true
        pQueue.enqueue(job)
        await pQueue.processNext()

        XCTAssertEqual(
            pQueue.jobs.first?.state, .done,
            "autoSkipNaming job must complete without parking at .speakerNamingPending",
        )
        XCTAssertNil(
            pQueue.speakerNamingDataByJob[job.id],
            "Auto-skipped job should not stash naming data awaiting resolution",
        )
    }

    func testCompleteSpeakerNamingLateConfirmedTransitionsToDone() async {
        let queue = PipelineQueue(logDir: tmpDir)
        var job = PipelineJob(
            meetingTitle: "Late Naming",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        queue.enqueue(job)

        // Simulate naming data still present
        let namingData = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Late Naming",
            mapping: [:],
            speakingTimes: [:],
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: false,
        )
        queue.speakerNamingDataByJob[job.id] = namingData

        let doneExpectation = XCTestExpectation(description: "Job transitions to done")
        queue.onJobStateChange = { _, _, newState in
            if newState == .done {
                doneExpectation.fulfill()
            }
        }

        // Late completion: no continuation, pipeline done → spawns async re-apply
        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed([:]))

        await fulfillment(of: [doneExpectation], timeout: 5)

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertNil(queue.speakerNamingDataByJob[job.id])
    }

    func testCompleteSpeakerNamingLateSkipTransitionsToDone() {
        let queue = PipelineQueue(logDir: tmpDir)
        var job = PipelineJob(
            meetingTitle: "Late Skip",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        queue.enqueue(job)

        let namingData = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Late Skip",
            mapping: [:],
            speakingTimes: [:],
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: false,
        )
        queue.speakerNamingDataByJob[job.id] = namingData

        // Late skip: synchronous cleanup
        queue.completeSpeakerNaming(jobID: job.id, result: .skipped)

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertNil(queue.speakerNamingDataByJob[job.id])
    }

    func testSkipTransitionsToDoneWhenProtocolFactoryReturnsNil() async throws {
        // Regression: when AppSettings.protocolProvider == .none, the
        // factory closure exists but returns nil. Earlier acceptAutoNames
        // checked closure-existence (always true here), took the Task
        // path, and that Task fizzled in generateProtocol's guard —
        // leaving the job stuck in .speakerNamingPending. The fix
        // probes the closure's output, so skip falls through to .done.
        let outputDir = tmpDir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let mixPath = tmpDir.appendingPathComponent("mix.wav")
        try Data([0]).write(to: mixPath)
        let transcriptPath = tmpDir.appendingPathComponent("transcript.txt")
        try "[00:00] SPEAKER_0: Hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: outputDir,
            logDir: tmpDir,
            diarizeEnabled: true,
        )

        var job = PipelineJob(
            meetingTitle: "Provider None Skip",
            appName: "Teams",
            mixPath: mixPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.transcriptPath = transcriptPath
        queue.enqueue(job)

        queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Provider None Skip",
            mapping: [:], speakingTimes: [:], embeddings: [:],
            audioPath: nil, segments: [], participants: [],
            isDualSource: false,
        )

        let doneExpectation = XCTestExpectation(description: "Job transitions to done after skip")
        queue.onJobStateChange = { _, _, newState in
            if newState == .done {
                doneExpectation.fulfill()
            }
        }

        queue.completeSpeakerNaming(jobID: job.id, result: .skipped)

        await fulfillment(of: [doneExpectation], timeout: 2)

        XCTAssertEqual(
            queue.jobs.first?.state, .done,
            "Skip with provider=.none must transition to .done, not stay in .speakerNamingPending",
        )
        XCTAssertNil(queue.speakerNamingDataByJob[job.id])
    }

    // MARK: - Late Re-apply Speaker Names

    func testLateConfirmationRewritesTranscript() async throws {
        // Create a transcript file with speaker labels
        let protocolsDir = tmpDir.appendingPathComponent("protocols")
        try FileManager.default.createDirectory(at: protocolsDir, withIntermediateDirectories: true)
        let transcriptPath = protocolsDir.appendingPathComponent("test_transcript.txt")
        let originalTranscript = "[00:00] SPEAKER_0: Hello world\n[00:05] SPEAKER_1: Hi there"
        try originalTranscript.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let queue = PipelineQueue(logDir: tmpDir)
        var job = PipelineJob(
            meetingTitle: "Rewrite Test",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.transcriptPath = transcriptPath
        queue.enqueue(job)

        let namingData = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Rewrite Test",
            mapping: ["SPEAKER_0": "SPEAKER_0", "SPEAKER_1": "SPEAKER_1"],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            embeddings: ["SPEAKER_0": [1, 0], "SPEAKER_1": [0, 1]],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: false,
        )
        queue.speakerNamingDataByJob[job.id] = namingData

        let doneExpectation = XCTestExpectation(description: "Job transitions to done")
        queue.onJobStateChange = { _, _, newState in
            if newState == .done {
                doneExpectation.fulfill()
            }
        }

        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice", "SPEAKER_1": "Speaker C"]))

        await fulfillment(of: [doneExpectation], timeout: 5)

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertNil(queue.speakerNamingDataByJob[job.id])

        // Verify transcript was rewritten with user-provided names
        let rewritten = try String(contentsOf: transcriptPath, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("] Alice: Hello world"), "Transcript should contain user-provided name Alice in formattedLine format")
        XCTAssertTrue(rewritten.contains("] Speaker C: Hi there"), "Transcript should contain user-provided name Speaker C in formattedLine format")
        XCTAssertFalse(rewritten.contains("SPEAKER_0:"), "Generic label should be replaced")
        XCTAssertFalse(rewritten.contains("SPEAKER_1:"), "Generic label should be replaced")
    }

    /// Regression test for dual-source `R_`/`M_` prefixed labels (the format
    /// actually produced by `assignSpeakersDualTrack`). These never had
    /// brackets around the speaker name in the saved transcript, so the
    /// pre-fix `replacingOccurrences(of: "[\(label)]", ...)` logic silently
    /// did nothing and Confirm appeared to do nothing in the .txt.
    func testLateConfirmationRewritesDualSourceLabels() async throws {
        let protocolsDir = tmpDir.appendingPathComponent("protocols")
        try FileManager.default.createDirectory(at: protocolsDir, withIntermediateDirectories: true)
        let transcriptPath = protocolsDir.appendingPathComponent("dualsource_transcript.txt")
        let originalTranscript = "[00:00] Roman Passler: Morgen.\n[00:30] R_S2: Hallo\n[00:42] R_S3: Hi\n[09:55] M_S0: Da kenne ich mich nicht aus."
        try originalTranscript.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let queue = PipelineQueue(logDir: tmpDir)
        var job = PipelineJob(
            meetingTitle: "Dual Source Test",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.transcriptPath = transcriptPath
        queue.enqueue(job)

        let namingData = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Dual Source Test",
            mapping: ["R_S2": "R_S2", "R_S3": "R_S3", "M_S0": "Roman Passler"],
            speakingTimes: ["R_S2": 5, "R_S3": 5, "M_S0": 5],
            embeddings: ["R_S2": [1, 0], "R_S3": [0, 1], "M_S0": [0, 0]],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: true,
        )
        queue.speakerNamingDataByJob[job.id] = namingData

        let doneExpectation = XCTestExpectation(description: "Job transitions to done")
        queue.onJobStateChange = { _, _, newState in
            if newState == .done {
                doneExpectation.fulfill()
            }
        }

        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed([
            "R_S2": "Lennart",
            "R_S3": "Diana",
        ]))

        await fulfillment(of: [doneExpectation], timeout: 5)

        let rewritten = try String(contentsOf: transcriptPath, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("] Lennart: Hallo"), "R_S2 should be renamed to Lennart")
        XCTAssertTrue(rewritten.contains("] Diana: Hi"), "R_S3 should be renamed to Diana")
        XCTAssertTrue(rewritten.contains("] Roman Passler: Morgen."), "Already-named speaker should be untouched")
        XCTAssertFalse(rewritten.contains("R_S2:"), "R_S2 label should be gone")
        XCTAssertFalse(rewritten.contains("R_S3:"), "R_S3 label should be gone")
    }

    func testLateConfirmationReplacesAutoMatchedNames() async throws {
        // Test that auto-matched names (from SpeakerMatcher) are also replaced
        let protocolsDir = tmpDir.appendingPathComponent("protocols")
        try FileManager.default.createDirectory(at: protocolsDir, withIntermediateDirectories: true)
        let transcriptPath = protocolsDir.appendingPathComponent("auto_match_transcript.txt")
        // Transcript already has auto-matched name "John" for SPEAKER_0
        let originalTranscript = "[00:00] John: Hello world"
        try originalTranscript.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let queue = PipelineQueue(logDir: tmpDir)
        var job = PipelineJob(
            meetingTitle: "Auto Match Test",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.transcriptPath = transcriptPath
        queue.enqueue(job)

        let namingData = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Auto Match Test",
            mapping: ["SPEAKER_0": "John"], // auto-matched to John
            speakingTimes: ["SPEAKER_0": 5],
            embeddings: ["SPEAKER_0": [1, 0]],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: false,
        )
        queue.speakerNamingDataByJob[job.id] = namingData

        let doneExpectation = XCTestExpectation(description: "done")
        queue.onJobStateChange = { _, _, newState in
            if newState == .done {
                doneExpectation.fulfill()
            }
        }

        // User corrects John → Jonathan
        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Jonathan"]))

        await fulfillment(of: [doneExpectation], timeout: 5)

        let rewritten = try String(contentsOf: transcriptPath, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("] Jonathan: Hello world"), "Auto-matched name should be replaced with user correction")
        XCTAssertFalse(rewritten.contains("John:"), "Old auto-matched name should be gone")
    }

    // MARK: - Late Re-diarization

    func testLateRerunDiarizesFromPersistedAudio() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]
        let mockDiar = MockDiarization()
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )
        // No handler → pipeline proceeds immediately with auto-names

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Late Rerun Test",
            appName: "TestApp",
            mixPath: audioPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        pQueue.enqueue(job)

        // Wait for speakerNamingPending (timeout path leaves naming data intact)
        let pendingExpectation = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending {
                pendingExpectation.fulfill()
            }
        }
        await pQueue.processNext()
        await fulfillment(of: [pendingExpectation], timeout: 10)

        XCTAssertEqual(pQueue.jobs.first?.state, .speakerNamingPending)
        XCTAssertNotNil(pQueue.speakerNamingDataByJob[job.id])

        // Now set handler to confirm after re-run
        var rerunHandlerCalled = false
        pQueue.speakerNamingHandler = { _ in
            rerunHandlerCalled = true
            return .confirmed([:])
        }

        // Request re-run with 3 speakers
        let doneExpectation = XCTestExpectation(description: "done after rerun")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done {
                doneExpectation.fulfill()
            }
        }

        pQueue.completeSpeakerNaming(jobID: job.id, result: .rerun(3))
        await fulfillment(of: [doneExpectation], timeout: 60)

        XCTAssertTrue(rerunHandlerCalled, "Handler should be called with new diarization results")
        XCTAssertEqual(pQueue.jobs.first?.state, .done)
    }

    /// Regression: a late re-run that detects MORE speakers than the initial
    /// diarization must re-segment the saved transcript, not just rename the
    /// labels that already exist in it. The original bug: the initial mix
    /// diarization collapsed to one speaker, the re-run correctly found three
    /// (shown in the dialog), but Confirm only string-replaced the single label
    /// present in the saved transcript — so the .txt still had one speaker.
    func testLateRerunConfirmRebuildsTranscriptWithNewSpeakers() async throws {
        let (pQueue, mockDiar, jobID) = try await makeSingleSourceJobAtNamingPending(
            title: "Rerun Rebuild Test",
            transcriptSegments: [
                TimestampedSegment(start: 0, end: 5, text: "Hello"),
                TimestampedSegment(start: 5, end: 10, text: "How are you"),
                TimestampedSegment(start: 10, end: 15, text: "Goodbye"),
            ],
        )

        // Sanity: the initial transcript really did collapse to one speaker.
        let initialPath = try XCTUnwrap(pQueue.jobs.first?.transcriptPath)
        let initialTranscript = try String(contentsOf: initialPath, encoding: .utf8)
        XCTAssertFalse(initialTranscript.contains("SPEAKER_1:"), "Setup precondition: initial diarization is single-speaker")

        // The re-run now detects three distinct speakers across the timeline.
        mockDiar.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
                .init(start: 10, end: 15, speaker: "SPEAKER_2"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5, "SPEAKER_2": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0], "SPEAKER_2": [0, 0, 1]],
        )

        pQueue.speakerNamingHandler = { _ in
            .confirmed(["SPEAKER_0": "Alice", "SPEAKER_1": "Bob", "SPEAKER_2": "Carol"])
        }

        let doneExpectation = XCTestExpectation(description: "done after rerun")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { doneExpectation.fulfill() }
        }
        pQueue.completeSpeakerNaming(jobID: jobID, result: .rerun(3))
        await fulfillment(of: [doneExpectation], timeout: 60)

        let finalPath = try XCTUnwrap(pQueue.jobs.first?.transcriptPath)
        let finalTranscript = try String(contentsOf: finalPath, encoding: .utf8)
        XCTAssertTrue(finalTranscript.contains("] Alice: Hello"), "First speaker should appear after re-run confirm")
        XCTAssertTrue(finalTranscript.contains("] Bob: How are you"), "Second speaker must survive into the transcript")
        XCTAssertTrue(finalTranscript.contains("] Carol: Goodbye"), "Third speaker must survive into the transcript")
    }

    /// Dual-source variant of the re-segment regression: a late re-run that
    /// splits the remote/app track into more speakers must re-segment the saved
    /// dual-track transcript, not just rename the labels already in it.
    func testLateRerunConfirmRebuildsDualSourceTranscript() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "First"),
            TimestampedSegment(start: 5, end: 10, text: "Second"),
        ]
        let mockDiar = MockDiarization()
        // Initial: one speaker per track → one remote speaker in the transcript.
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 10, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 10],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        try pQueue.enqueue(makeDualSourceJob(title: "Dual Rerun Rebuild"))
        let jobID = try XCTUnwrap(pQueue.jobs.first?.id)
        let pending = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending { pending.fulfill() }
        }
        await pQueue.processNext()
        await fulfillment(of: [pending], timeout: 10)

        let initialPath = try XCTUnwrap(pQueue.jobs.first?.transcriptPath)
        let initialTranscript = try String(contentsOf: initialPath, encoding: .utf8)
        XCTAssertFalse(initialTranscript.contains("R_SPEAKER_1:"), "Setup precondition: one remote speaker initially")

        // Re-run splits the remote/app track into two speakers across the timeline.
        mockDiar.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )
        pQueue.speakerNamingHandler = { _ in
            .confirmed(["R_SPEAKER_0": "Alice", "R_SPEAKER_1": "Bob"])
        }
        let done = XCTestExpectation(description: "done after dual rerun")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { done.fulfill() }
        }
        pQueue.completeSpeakerNaming(jobID: jobID, result: .rerun(2))
        await fulfillment(of: [done], timeout: 60)

        let finalPath = try XCTUnwrap(pQueue.jobs.first?.transcriptPath)
        let finalTranscript = try String(contentsOf: finalPath, encoding: .utf8)
        XCTAssertTrue(finalTranscript.contains("] Alice: First"), "First remote speaker should appear after re-run confirm")
        XCTAssertTrue(finalTranscript.contains("] Bob: Second"), "Second remote speaker must survive into the transcript")
    }

    /// The re-run rewrite happens before the dialog result is known, so a
    /// re-run followed by SKIP (accept auto-names) must also carry the new
    /// segmentation into the saved transcript — the rewrite must not depend on
    /// a confirm mapping.
    func testLateRerunSkipKeepsRebuiltSegmentation() async throws {
        let (pQueue, mockDiar, jobID) = try await makeSingleSourceJobAtNamingPending(
            title: "Rerun Skip Test",
            transcriptSegments: [
                TimestampedSegment(start: 0, end: 5, text: "Hello"),
                TimestampedSegment(start: 5, end: 10, text: "How are you"),
                TimestampedSegment(start: 10, end: 15, text: "Goodbye"),
            ],
        )

        mockDiar.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
                .init(start: 10, end: 15, speaker: "SPEAKER_2"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5, "SPEAKER_2": 5], autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0], "SPEAKER_2": [0, 0, 1]],
        )
        pQueue.speakerNamingHandler = { _ in .skipped }
        let done = XCTestExpectation(description: "done after rerun skip")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { done.fulfill() }
        }
        pQueue.completeSpeakerNaming(jobID: jobID, result: .rerun(3))
        await fulfillment(of: [done], timeout: 60)

        let finalTranscript = try String(contentsOf: XCTUnwrap(pQueue.jobs.first?.transcriptPath), encoding: .utf8)
        XCTAssertTrue(finalTranscript.contains("SPEAKER_1:"), "Skip must keep the re-run's added speakers (auto-named)")
        XCTAssertTrue(finalTranscript.contains("SPEAKER_2:"), "Skip must keep all re-run speakers")
    }

    /// When the persisted transcript segments are absent (older recordings
    /// predating segment persistence), the re-run rewrite degrades gracefully:
    /// it does NOT wipe the transcript, and surfaces a warning so the user
    /// isn't silently misled into thinking the new speakers were applied.
    func testLateRerunWithoutPersistedSegmentsWarnsAndKeepsTranscript() async throws {
        let (pQueue, mockDiar, jobID) = try await makeSingleSourceJobAtNamingPending(
            title: "No Segments Test",
            transcriptSegments: [
                TimestampedSegment(start: 0, end: 5, text: "Hello"),
                TimestampedSegment(start: 5, end: 10, text: "World"),
            ],
        )

        let transcriptPath = try XCTUnwrap(pQueue.jobs.first?.transcriptPath)
        let before = try String(contentsOf: transcriptPath, encoding: .utf8)
        // Simulate an older recording: remove the persisted transcript segments.
        let slug = try XCTUnwrap(pQueue.jobs.first?.namingSlug)
        try FileManager.default.removeItem(
            at: tmpDir.appendingPathComponent("recordings").appendingPathComponent("\(slug)_segments.json"),
        )

        mockDiar.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5], autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )
        pQueue.speakerNamingHandler = { _ in .skipped }
        let done = XCTestExpectation(description: "done")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { done.fulfill() }
        }
        pQueue.completeSpeakerNaming(jobID: jobID, result: .rerun(2))
        await fulfillment(of: [done], timeout: 60)

        let after = try String(contentsOf: transcriptPath, encoding: .utf8)
        XCTAssertEqual(after, before, "Missing segments must not wipe or alter the saved transcript")
        let warnings = try XCTUnwrap(pQueue.jobs.first?.warnings)
        XCTAssertTrue(
            warnings.contains { $0.contains("no saved transcript segments") },
            "User should be warned the re-run could not re-segment — got: \(warnings)",
        )
    }

    /// A transcript-write failure during the re-run rewrite (e.g. the output
    /// directory vanished) must degrade gracefully: the rewrite's catch swallows
    /// it and the job still reaches a terminal state rather than wedging.
    func testLateRerunTranscriptWriteFailureIsNonFatal() async throws {
        let (pQueue, mockDiar, jobID) = try await makeSingleSourceJobAtNamingPending(
            title: "Write Fail Test",
            transcriptSegments: [
                TimestampedSegment(start: 0, end: 5, text: "Hello"),
                TimestampedSegment(start: 5, end: 10, text: "World"),
            ],
        )

        // Force the rewrite's write to fail: delete the protocols directory so
        // the atomic write to the job's transcriptPath has no parent. The
        // persisted segments live in recordings/, so loadCachedSegments still
        // succeeds and the failure lands in the write (not the no-segments early
        // return). Confirm (not skip) so the job still reaches .done despite the
        // now-missing transcript file.
        try FileManager.default.removeItem(at: tmpDir.appendingPathComponent("protocols"))

        mockDiar.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5], autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )
        pQueue.speakerNamingHandler = { _ in .confirmed([:]) }
        let done = XCTestExpectation(description: "done despite write failure")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { done.fulfill() }
        }
        let transcriptPath = try XCTUnwrap(pQueue.jobs.first?.transcriptPath)
        pQueue.completeSpeakerNaming(jobID: jobID, result: .rerun(2))
        await fulfillment(of: [done], timeout: 60)

        XCTAssertEqual(pQueue.jobs.first?.state, .done, "Write failure during re-segmentation must not wedge the job")
        // Proves the write genuinely failed (exercising the rewrite's catch):
        // the atomic write can't recreate the deleted parent directory, so no
        // transcript file exists afterwards.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: transcriptPath.path),
            "The rewrite write must have failed (no parent dir), exercising the catch path",
        )
    }

    /// Factory helper for the mode-override integration tests. Returns a
    /// `MockDiarization` with `.mode` set + a small fixture result keyed off
    /// the mode, so the two test bodies can verify which provider was used.
    private func makeModeOverrideDiar(_ mode: DiarizerMode) -> MockDiarization {
        let mock = MockDiarization()
        mock.mode = mode
        mock.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 2, speaker: "SPEAKER_0"),
                .init(start: 2, end: 5, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 2, "SPEAKER_1": 3],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )
        return mock
    }

    /// `.rerunWithMode(.sortformer, _)` swaps the `DiarizationProvider`
    /// through the mode-aware factory and writes the new mode back onto
    /// `PipelineJob.usedDiarizerMode`. Regression gate for the mode↔count
    /// coupling: a missing wire-through here means the picker in
    /// `SpeakerNamingView` becomes ghost UI in Sortformer mode.
    func testLateRerunWithModeOverrideSwapsProviderAndRecordsMode() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let offlineDiar = makeModeOverrideDiar(.offline)
        let sortformerDiar = makeModeOverrideDiar(.sortformer)
        let modeOverrideCalls = OSAllocatedUnfairLock<[DiarizerMode]>(initialState: [])
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { offlineDiar },
            diarizationFactoryWithMode: { mode in
                modeOverrideCalls.withLock { $0.append(mode) }
                return mode == .sortformer ? sortformerDiar : offlineDiar
            },
            diarizeEnabled: true,
        )

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Mode Override Test", appName: "TestApp",
            mixPath: audioPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        let pendingExpectation = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending { pendingExpectation.fulfill() }
        }
        await pQueue.processNext()
        await fulfillment(of: [pendingExpectation], timeout: 10)
        XCTAssertEqual(pQueue.jobs.first?.usedDiarizerMode, .offline)

        pQueue.speakerNamingHandler = { _ in .confirmed([:]) }
        let doneExpectation = XCTestExpectation(description: "done after mode override")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done { doneExpectation.fulfill() }
        }
        pQueue.completeSpeakerNaming(jobID: job.id, result: .rerunWithMode(.sortformer, 2))
        await fulfillment(of: [doneExpectation], timeout: 60)

        XCTAssertEqual(modeOverrideCalls.withLock(\.self), [.sortformer])
        XCTAssertEqual(pQueue.jobs.first?.usedDiarizerMode, .sortformer)
        XCTAssertEqual(pQueue.jobs.first?.state, .done)
    }

    /// `.rerunWithMode(_, _)` falls back to the no-arg factory when no
    /// mode-aware factory is wired (covers tests and any callsite that
    /// hasn't been migrated yet). The mode metadata follows the actual
    /// provider — so a default-mode `MockDiarization` keeps the job's
    /// `usedDiarizerMode` consistent with what ran.
    func testLateRerunWithModeOverrideFallsBackToDefaultFactory() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
        ]
        let mockDiar = MockDiarization()
        mockDiar.mode = .offline
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        // No `diarizationFactoryWithMode` provided — covers the fallback path.
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Mode Override Fallback Test",
            appName: "TestApp",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)

        let pendingExpectation = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending {
                pendingExpectation.fulfill()
            }
        }
        await pQueue.processNext()
        await fulfillment(of: [pendingExpectation], timeout: 10)

        pQueue.speakerNamingHandler = { _ in .confirmed([:]) }
        let doneExpectation = XCTestExpectation(description: "done after fallback")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .done {
                doneExpectation.fulfill()
            }
        }

        pQueue.completeSpeakerNaming(
            jobID: job.id,
            result: .rerunWithMode(.sortformer, 2),
        )
        await fulfillment(of: [doneExpectation], timeout: 60)

        // Without a mode-aware factory, the fallback runs the no-arg
        // factory and the resulting provider's mode (.offline) wins.
        XCTAssertEqual(pQueue.jobs.first?.usedDiarizerMode, .offline)
    }

    /// `lateDiarization` swallows diarizer errors and rolls the job back
    /// to `.speakerNamingPending` (so the user can try again) without
    /// touching `usedDiarizerMode` — the cached naming data still
    /// reflects the prior successful run.
    func testLateRerunRollsBackToPendingWhenDiarizerThrows() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let mockDiar = MockDiarization()
        mockDiar.mode = .offline
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Late Rerun Throw Test", appName: "TestApp",
            mixPath: audioPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        let pendingExpectation = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending { pendingExpectation.fulfill() }
        }
        await pQueue.processNext()
        await fulfillment(of: [pendingExpectation], timeout: 10)
        XCTAssertEqual(pQueue.jobs.first?.usedDiarizerMode, .offline)

        // Make the diarizer throw on the next run (the `_16k.wav` re-run path).
        mockDiar.throwOnPathSuffix = "_16k.wav"

        let rolledBack = XCTestExpectation(description: "rolled back to pending after throw")
        var seenStates: [JobState] = []
        pQueue.onJobStateChange = { _, _, newState in
            seenStates.append(newState)
            if seenStates.contains(.diarizing), newState == .speakerNamingPending {
                rolledBack.fulfill()
            }
        }
        pQueue.completeSpeakerNaming(jobID: job.id, result: .rerun(2))
        await fulfillment(of: [rolledBack], timeout: 10)

        XCTAssertEqual(pQueue.jobs.first?.state, .speakerNamingPending)
        // usedDiarizerMode is unchanged from the prior successful run
        // because the cached naming data still reflects that run.
        XCTAssertEqual(pQueue.jobs.first?.usedDiarizerMode, .offline)
    }

    /// Late re-run of a dual-source job whose mic track fails to diarize must
    /// fall back to the *unprefixed* app-only diarization — mirroring the batch
    /// `runDiarization` path — instead of throwing (a silent no-op that bounces
    /// the job back to pending) or emitting `R_`-prefixed keys that no longer
    /// match the persisted app-only transcript. Regression guard for the
    /// late-path sibling of the batch mic-fail app-name-loss bug.
    func testLateRerunDualSourceMicFailFallsBackToAppOnly() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let mockDiar = MockDiarization()
        mockDiar.mode = .offline
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        // First run: both tracks succeed → reach speakerNamingPending with
        // persisted naming data + namingSlug + persisted _app_16k/_mic_16k audio.
        try pQueue.enqueue(makeDualSourceJob(title: "Late MicFail"))
        let job = try XCTUnwrap(pQueue.jobs.first)
        let pendingExpectation = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending { pendingExpectation.fulfill() }
        }
        await pQueue.processNext()
        await fulfillment(of: [pendingExpectation], timeout: 10)

        // Re-run: make ONLY the mic track fail. The fallback must still drive the
        // naming dialog (no silent no-op) with the raw, unprefixed app keys.
        mockDiar.throwOnPathSuffix = "_mic_16k.wav"
        var rerunKeys: [String] = []
        // The handler firing at all proves the fallback ran — the buggy path
        // throws on the mic track and bounces back to pending without calling it.
        let handlerCalled = XCTestExpectation(description: "naming handler called after mic-fail fallback")
        pQueue.speakerNamingHandler = { data in
            rerunKeys = Array(data.mapping.keys)
            handlerCalled.fulfill()
            return .confirmed([:])
        }

        pQueue.completeSpeakerNaming(jobID: job.id, result: .rerun(2))
        await fulfillment(of: [handlerCalled], timeout: 10)

        XCTAssertTrue(
            rerunKeys.contains("SPEAKER_0"),
            "fallback should expose the raw app diarization keys — got: \(rerunKeys)",
        )
        XCTAssertFalse(
            rerunKeys.contains { $0.hasPrefix("R_") || $0.hasPrefix("M_") },
            "mic-fail fallback must use the unprefixed app diarization, not the R_/M_ merge — got: \(rerunKeys)",
        )
        let warnings = try XCTUnwrap(pQueue.jobs.first?.warnings)
        XCTAssertTrue(
            warnings.contains { $0.contains("Mic track diarization failed") },
            "late mic-fail fallback should add a warning, like the batch path — got: \(warnings)",
        )
    }

    /// The late re-run path (`runLateDiarization`) threads the job's `micDelay`
    /// into the shared dual-track helper, so its mic diarization is shifted onto
    /// the canonical timeline exactly like the batch path
    /// (`testDiarizeDualTrackShiftsMicDiarizationByMicDelay`). Pinned separately
    /// because the late re-run is a distinct caller: dropping `micDelay` from its
    /// `recording` tuple (threading 0) would silently misalign re-run mic labels
    /// — the same misalignment the batch-path shift prevents — and the batch test
    /// would not catch it.
    func testLateRerunDualSourceShiftsMicDiarizationByMicDelay() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let mockDiar = MockDiarization()
        // Both tracks diarize the same raw [0,5] segment (the mock ignores the
        // audio path). The mic copy must be shifted by +micDelay onto the
        // canonical timeline before the R_/M_ merge.
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        // First run → speakerNamingPending (persists _app_16k/_mic_16k + naming).
        try pQueue.enqueue(makeDualSourceJob(title: "Late MicDelay", micDelay: 100))
        let jobID = try XCTUnwrap(pQueue.jobs.first?.id)
        let pending = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending { pending.fulfill() }
        }
        await pQueue.processNext()
        await fulfillment(of: [pending], timeout: 10)

        // Re-run via the late path: capture its fresh naming data, then finish.
        var rerunData: PipelineQueue.SpeakerNamingData?
        let handlerCalled = XCTestExpectation(description: "naming handler called on re-run")
        pQueue.speakerNamingHandler = { data in
            rerunData = data
            handlerCalled.fulfill()
            return .confirmed([:])
        }
        pQueue.completeSpeakerNaming(jobID: jobID, result: .rerun(2))
        await fulfillment(of: [handlerCalled], timeout: 10)

        // The mic track's raw [0,5] diarization must be shifted by +micDelay
        // (100s) → the merged M_-prefixed mic segment sits at [100,105]. A late
        // path that threaded micDelay=0 would leave it at [0,5].
        let segments = try XCTUnwrap(rerunData).segments
        let micSegment = try XCTUnwrap(
            segments.first { $0.speaker.hasPrefix("M_") },
            "re-run naming data should include a mic-track (M_) segment — got: \(segments.map(\.speaker))",
        )
        XCTAssertEqual(
            micSegment.start, 100, accuracy: 0.001,
            "late re-run must shift mic diarization by micDelay (100s) — got start=\(micSegment.start)",
        )
    }

    /// `isAvailable == false` short-circuits lateDiarization without
    /// changing the job state — there's no recoverable path so the
    /// user is left to fix the configuration (model download, etc.).
    func testLateRerunIsNoOpWhenDiarizerNotAvailable() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let mockDiar = MockDiarization()
        mockDiar.mode = .offline
        mockDiar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let (pQueue, _) = makeMockProcessingQueue(
            engine: engine,
            diarizationFactory: { mockDiar },
            diarizeEnabled: true,
        )

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Late Rerun Unavailable", appName: "TestApp",
            mixPath: audioPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        let pendingExpectation = XCTestExpectation(description: "speakerNamingPending")
        pQueue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending { pendingExpectation.fulfill() }
        }
        await pQueue.processNext()
        await fulfillment(of: [pendingExpectation], timeout: 10)

        // Flip the mock to "not available" so the late-rerun guard at the
        // top of lateDiarization trips.
        mockDiar.isAvailable = false
        let initialState = pQueue.jobs.first?.state
        pQueue.completeSpeakerNaming(jobID: job.id, result: .rerun(3))
        // Yield once to let the Task dispatched from completeSpeakerNaming
        // observe the unavailable guard and return early.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(pQueue.jobs.first?.state, initialState)
    }

    func testLateConfirmationWithNoNamingDataIsNoOp() {
        let queue = PipelineQueue(logDir: tmpDir)
        var job = PipelineJob(
            meetingTitle: "No Data Test",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        queue.enqueue(job)

        // No naming data set — should be a no-op
        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))

        // State should NOT change since guard fails
        XCTAssertEqual(queue.jobs.first?.state, .speakerNamingPending)
    }

    // MARK: - Snapshot Restore + Speaker Naming Cache

    func testLoadSnapshotRebuildsSpeakerNamingCache() throws {
        let outputDir = tmpDir.appendingPathComponent("output")
        let recordingsDir = outputDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let mixPath = tmpDir.appendingPathComponent("mix.wav")
        try Data([0]).write(to: mixPath)

        // Create a job in speakerNamingPending state and write snapshot JSON directly
        var job = PipelineJob(
            meetingTitle: "Snapshot Test",
            appName: "App",
            mixPath: mixPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.namingSlug = "snapshot_test"
        let snapshotData = try JSONEncoder().encode([job])
        try snapshotData.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        // Save naming data as sidecar JSON
        let namingData = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Snapshot Test",
            mapping: ["SPEAKER_0": "Alice"],
            speakingTimes: ["SPEAKER_0": 60.0],
            embeddings: ["SPEAKER_0": [0.1, 0.2]],
            audioPath: recordingsDir.appendingPathComponent("snapshot_test_16k.wav"),
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            participants: [],
            isDualSource: false,
        )
        let json = try JSONEncoder().encode(namingData)
        try json.write(to: recordingsDir.appendingPathComponent("snapshot_test_naming.json"))

        // Load snapshot in a new queue that has outputDir set
        let mockEngine = MockEngine()
        let freshQueue = PipelineQueue(
            engine: mockEngine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: outputDir,
            logDir: tmpDir,
            diarizeEnabled: true,
        )
        freshQueue.loadSnapshot()

        // Verify: job still in speakerNamingPending, naming data loaded
        XCTAssertEqual(freshQueue.jobs.first?.state, .speakerNamingPending)
        XCTAssertNotNil(try freshQueue.speakerNamingDataByJob[XCTUnwrap(freshQueue.jobs.first?.id)])
        XCTAssertEqual(
            try freshQueue.speakerNamingDataByJob[XCTUnwrap(freshQueue.jobs.first?.id)]?.mapping["SPEAKER_0"],
            "Alice",
        )
    }

    func testLoadSnapshotFallsToDoneWhenNamingDataMissing() throws {
        let mixPath = tmpDir.appendingPathComponent("mix.wav")
        try Data([0]).write(to: mixPath)

        var job = PipelineJob(
            meetingTitle: "Missing Data Test",
            appName: "App",
            mixPath: mixPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.namingSlug = "missing_data_test"
        let snapshotData = try JSONEncoder().encode([job])
        try snapshotData.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        // Load without saving naming JSON — should fall back to .done
        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        // Job transitions to .done in the naming rebuild loop (after removeAll ran),
        // so it remains in the list as .done
        let finalJob = freshQueue.jobs.first
        XCTAssertEqual(finalJob?.state, .done)
    }

    // MARK: - Stale Pending Cleanup

    func testCleanupStalePendingTransitionsToDone() {
        var job = PipelineJob(
            meetingTitle: "Old Meeting",
            appName: "App",
            mixPath: tmpDir.appendingPathComponent("mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = .speakerNamingPending
        queue.enqueue(job)

        // enqueuedAt is "now" — calling with maxAge: 0 should clean it up
        queue.cleanupStalePending(maxAge: 0)

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertNil(queue.speakerNamingDataByJob[job.id])
    }

    func testCleanupStalePendingKeepsRecentJobs() {
        var job = PipelineJob(
            meetingTitle: "Recent Meeting",
            appName: "App",
            mixPath: tmpDir.appendingPathComponent("mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = .speakerNamingPending
        queue.enqueue(job)

        // With default 24h maxAge, a fresh job should not be cleaned up
        queue.cleanupStalePending()

        XCTAssertEqual(queue.jobs.first?.state, .speakerNamingPending)
    }

    // MARK: - knownSpeakerNames cache (issue #155)

    //
    // The SpeakerNamingView dialog used to call
    // `appState.pipeline.queue.speakerMatcherFactory().allSpeakerNames()`
    // inside the SwiftUI body getter. Each body re-eval re-constructed a
    // SpeakerMatcher (running migrateIfNeeded → file read) and re-parsed
    // the entire speakers.json (including embeddings) just to extract
    // names — pinning the main thread at 100% CPU after extended uptime.
    //
    // Fix: cache the result on PipelineQueue, refresh only on updateDB
    // and explicit calls. UI reads `pipelineQueue.knownSpeakerNames`
    // directly with zero per-render I/O.

    func testKnownSpeakerNamesIsExposedAsCachedProperty() {
        // The cached property must exist on PipelineQueue. Empty DB → empty list.
        let dbURL = tmpDir.appendingPathComponent("speakers.json")
        let localQueue = PipelineQueue(
            logDir: tmpDir,
        ) { SpeakerMatcher(dbPath: dbURL) }
        XCTAssertEqual(localQueue.knownSpeakerNames, [])
    }

    func testKnownSpeakerNamesReflectsDBAfterRefresh() {
        let dbURL = tmpDir.appendingPathComponent("speakers.json")
        // Seed the on-disk DB before constructing the queue.
        let seeded = SpeakerMatcher(dbPath: dbURL)
        seeded.updateDB(
            mapping: ["S0": "Alice", "S1": "Bob"],
            embeddings: ["S0": [0.1, 0.2], "S1": [0.3, 0.4]],
        )

        let localQueue = PipelineQueue(
            logDir: tmpDir,
        ) { SpeakerMatcher(dbPath: dbURL) }
        localQueue.refreshKnownSpeakerNames()

        XCTAssertEqual(Set(localQueue.knownSpeakerNames), Set(["Alice", "Bob"]))
    }

    func testKnownSpeakerNamesRefreshesAfterFactoryDBChange() {
        let dbURL = tmpDir.appendingPathComponent("speakers.json")
        let localQueue = PipelineQueue(
            logDir: tmpDir,
        ) { SpeakerMatcher(dbPath: dbURL) }
        localQueue.refreshKnownSpeakerNames()
        XCTAssertEqual(localQueue.knownSpeakerNames, [], "Empty DB at start")

        // Simulate a recognition outcome that adds a new speaker.
        let matcher = localQueue.speakerMatcherFactory()
        matcher.updateDB(
            mapping: ["S0": "Charlie"], embeddings: ["S0": [0.5, 0.6]],
        )
        localQueue.refreshKnownSpeakerNames()

        XCTAssertEqual(localQueue.knownSpeakerNames, ["Charlie"])
    }

    func testKnownSpeakerNamesReadsAreFreeFromFactoryInvocation() {
        // Property reads must not invoke the factory — that's the whole
        // point of the cache. The factory is the heavy operation that was
        // re-firing per SwiftUI render in the bug report.
        let dbURL = tmpDir.appendingPathComponent("speakers.json")
        var factoryCalls = 0
        let localQueue = PipelineQueue(
            logDir: tmpDir,
        ) {
            factoryCalls += 1
            return SpeakerMatcher(dbPath: dbURL)
        }
        localQueue.refreshKnownSpeakerNames()
        let baseline = factoryCalls

        for _ in 0 ..< 10 {
            _ = localQueue.knownSpeakerNames
        }

        XCTAssertEqual(
            factoryCalls, baseline,
            "Reading knownSpeakerNames must not invoke speakerMatcherFactory",
        )
    }

    // MARK: - M3: slug uniqueness

    /// Two back-to-back meetings with identical titles (e.g. recurring
    /// "Daily Standup") would otherwise share the same on-disk slug — the
    /// second job's `_naming.json` / `_16k.wav` overwrites the first's, and
    /// snapshot rebuild then maps the survivor's data onto both UUIDs.
    /// Embedding the job's short-id keeps each on-disk artefact distinct.
    func test_namingSlug_differsForSameTitleDifferentJobs() {
        let id1 = UUID()
        let id2 = UUID()
        let slug1 = PipelineQueue.namingSlug(title: "Daily Standup", jobID: id1)
        let slug2 = PipelineQueue.namingSlug(title: "Daily Standup", jobID: id2)
        XCTAssertNotEqual(
            slug1, slug2,
            "Identical titles must produce distinct slugs when job IDs differ",
        )
    }

    /// Determinism: same input → same slug. Snapshot rebuild relies on this
    /// to find a job's persisted `_naming.json` after a relaunch.
    func test_namingSlug_isDeterministicForSameJob() {
        let id = UUID()
        let first = PipelineQueue.namingSlug(title: "Daily Standup", jobID: id)
        let second = PipelineQueue.namingSlug(title: "Daily Standup", jobID: id)
        XCTAssertEqual(first, second)
    }

    func test_namingSlug_embedsTitleAndShortID() {
        let id = UUID()
        let slug = PipelineQueue.namingSlug(title: "Daily Standup", jobID: id)
        XCTAssertTrue(
            slug.contains(PipelineJob.shortID(for: id)),
            "Slug must include the job short-ID for uniqueness across same-title runs",
        )
        // Title-derived part should still be present (filesystem-friendly form).
        XCTAssertTrue(
            slug.lowercased().contains("daily") && slug.lowercased().contains("standup"),
            "Slug should still encode the title for human-readable filenames",
        )
    }
}
