import XCTest
@testable import MeetingTranscriber

@MainActor
final class PipelineQueueTests: XCTestCase {

    private var tmpDir: URL!
    private var queue: PipelineQueue!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline_queue_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        queue = PipelineQueue(logDir: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeJob(title: String = "Test Meeting") -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0
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

    func testSnapshotWrittenOnEnqueue() {
        queue.enqueue(makeJob())
        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath.path))
    }

    func testSnapshotIsValidJSON() throws {
        queue.enqueue(makeJob(title: "Standup"))
        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
        let data = try Data(contentsOf: snapshotPath)
        let jobs = try JSONDecoder().decode([PipelineJob].self, from: data)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].meetingTitle, "Standup")
    }

    func testLogAppendedOnEnqueue() throws {
        queue.enqueue(makeJob())
        let logPath = tmpDir.appendingPathComponent("pipeline_log.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath.path))
        let content = try String(contentsOf: logPath, encoding: .utf8)
        XCTAssertTrue(content.contains("enqueued"))
    }

    func testActiveJobs() {
        var job1 = makeJob(title: "Active")
        job1.state = .transcribing
        queue.enqueue(job1)
        queue.enqueue(makeJob(title: "Waiting"))
        XCTAssertEqual(queue.activeJobs.count, 1)
        XCTAssertEqual(queue.activeJobs[0].meetingTitle, "Active")
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
            appPath: nil, micPath: nil, micDelay: 0
        )
        let data = try JSONEncoder().encode([job])
        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
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
            appPath: nil, micPath: nil, micDelay: 0
        )
        job.state = .transcribing
        let data = try JSONEncoder().encode([job])
        try data.write(to: tmpDir.appendingPathComponent("pipeline_queue.json"))

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
            appPath: nil, micPath: nil, micDelay: 0
        )
        job.state = .done
        let data = try JSONEncoder().encode([job])
        try data.write(to: tmpDir.appendingPathComponent("pipeline_queue.json"))

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.loadSnapshot()

        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testLoadSnapshotDiscardsMissingAudio() throws {
        let job = PipelineJob(
            meetingTitle: "Ghost Meeting",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).wav"),
            appPath: nil, micPath: nil, micDelay: 0
        )
        let data = try JSONEncoder().encode([job])
        try data.write(to: tmpDir.appendingPathComponent("pipeline_queue.json"))

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

    func testRecoverFindsUntrackedMixWav() throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)

        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertEqual(freshQueue.jobs[0].meetingTitle, "Recovered Recording (20260311_100000)")
        XCTAssertEqual(
            freshQueue.jobs[0].mixPath.standardizedFileURL,
            mixFile.standardizedFileURL
        )
    }

    func testRecoverSkipsTrackedFiles() throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        let existing = PipelineJob(
            meetingTitle: "Already Tracked",
            appName: "Teams",
            mixPath: mixFile,
            appPath: nil, micPath: nil, micDelay: 0
        )
        freshQueue.enqueue(existing)

        freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertEqual(freshQueue.jobs[0].meetingTitle, "Already Tracked")
    }

    func testRecoverSkipsTinyFiles() throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data(repeating: 0x00, count: 44).write(to: mixFile)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)

        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testRecoverFindsCompanionTracks() throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let prefix = "20260311_100000"
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("\(prefix)_mix.wav"))
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("\(prefix)_app.wav"))
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("\(prefix)_mic.wav"))

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)

        XCTAssertEqual(freshQueue.jobs.count, 1)
        XCTAssertNotNil(freshQueue.jobs[0].appPath)
        XCTAssertNotNil(freshQueue.jobs[0].micPath)
    }

    func testRecoverSkipsOldFiles() throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20250101_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.recoverOrphanedRecordings(recordingsDir: recDir, maxAge: 0)

        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testRecoverSkipsProcessedFiles() throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let mixFile = recDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixFile)

        // Mark it as already processed
        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.markProcessed(mixPath: mixFile)

        freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertEqual(freshQueue.jobs.count, 0)
    }

    func testMarkProcessedPersists() throws {
        let mixPath = tmpDir.appendingPathComponent("test_mix.wav")

        let q1 = PipelineQueue(logDir: tmpDir)
        q1.markProcessed(mixPath: mixPath)

        // New queue instance should see the processed path
        let q2 = PipelineQueue(logDir: tmpDir)
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        // Create a file with the same standardized name
        try Data(repeating: 0xFF, count: 100).write(to: mixPath)

        // Won't find it if the path is in processed list — but the file is in tmpDir not recDir
        // So test directly via the processed set behavior
        let processedPath = tmpDir.appendingPathComponent("processed_recordings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: processedPath.path))
        let data = try Data(contentsOf: processedPath)
        let paths = try JSONDecoder().decode([String].self, from: data)
        XCTAssertTrue(paths.contains(mixPath.standardizedFileURL.path))
    }

    func testRecoverEmptyDirIsNoOp() {
        let recDir = tmpDir.appendingPathComponent("nonexistent_recordings")
        let freshQueue = PipelineQueue(logDir: tmpDir)
        freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertTrue(freshQueue.jobs.isEmpty)
    }

    // MARK: - Processing Tests

    private func makeProcessingQueue() -> PipelineQueue {
        PipelineQueue(
            logDir: tmpDir,
            whisperKit: WhisperKitEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            diarizeEnabled: false,
            micLabel: "Me"
        )
    }

    func testProcessNextPicksFirstWaitingJob() async throws {
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

    func testIsProcessingFlag() async {
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
}
