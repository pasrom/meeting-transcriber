// swiftlint:disable file_length
@testable import MeetingTranscriber
import XCTest

@MainActor
// swiftlint:disable:next attributes type_body_length
final class PipelineQueueTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var queue: PipelineQueue!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline_queue_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        queue = PipelineQueue(logDir: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
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

    func testCancelDuringSpeakerNamingResumesContinuation() async {
        let job = makeJob()
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .diarizing)
        queue.pendingSpeakerNaming = PipelineQueue.SpeakerNamingData(
            jobID: job.id,
            meetingTitle: "Test",
            mapping: [:],
            speakingTimes: [:],
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: [],
        )
        // Drive the actual fix path: a pending continuation that must resume.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<PipelineQueue.SpeakerNamingResult, Never>) in
            queue.setSpeakerNamingContinuationForTesting(continuation)
            queue.cancelJob(id: job.id)
        }

        if case .skipped = result {
            // expected
        } else {
            XCTFail("expected .skipped, got \(result)")
        }
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
            appPath: nil, micPath: nil, micDelay: 0,
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
            appPath: nil, micPath: nil, micDelay: 0,
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
            appPath: nil, micPath: nil, micDelay: 0,
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
            mixFile.standardizedFileURL,
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
            appPath: nil, micPath: nil, micDelay: 0,
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

    func testErrorJobIsMarkedProcessedSoRecoverySkipsIt() throws {
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
        freshQueue.recoverOrphanedRecordings(recordingsDir: recDir)
        XCTAssertTrue(freshQueue.jobs.isEmpty, "Failed recording should not be re-queued")
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
        diarizationFactory: @escaping () -> DiarizationProvider = { MockDiarization() },
        diarizeEnabled: Bool = false,
        numSpeakers: Int = 0,
    ) -> (PipelineQueue, MockEngine) {
        let engine = engine ?? MockEngine()
        let q = PipelineQueue(
            engine: engine,
            diarizationFactory: diarizationFactory,
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

        let audioPath = try createTestAudioFile(in: tmpDir)
        let appPath = tmpDir.appendingPathComponent("app_audio.wav")
        let micPath = tmpDir.appendingPathComponent("mic_audio.wav")
        try FileManager.default.copyItem(at: audioPath, to: appPath)
        try FileManager.default.copyItem(at: audioPath, to: micPath)

        let job = PipelineJob(
            meetingTitle: "Dual Source",
            appName: "Teams",
            mixPath: audioPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()

        // Dual source: transcribes app + mic = 2 calls
        XCTAssertEqual(engine.transcribeCallCount, 2)
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

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Naming Test",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()

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

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Skip Test",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()

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

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Rerun Test",
            appName: "Teams",
            mixPath: audioPath,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        pQueue.enqueue(job)
        await pQueue.processNext()

        // Handler should be called twice (first returns rerun, second returns skipped)
        XCTAssertEqual(callCount, 2)
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
        try data.write(to: tmpDir.appendingPathComponent("pipeline_queue.json"))

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
        try data.write(to: tmpDir.appendingPathComponent("pipeline_queue.json"))

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
        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
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

        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
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
}
