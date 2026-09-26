@testable import MeetingTranscriber
import XCTest

extension PipelineQueue {
    /// Insert a job for `mixPath` already in `state`, bypassing `enqueue()`
    /// and processing, and return its ID. For tests that need a job in a
    /// given state without running the pipeline to get it there.
    @discardableResult
    func insertJobForTesting(
        mixPath: URL, state: JobState, error: String? = nil, title: String = "Test Job",
    ) -> UUID {
        var job = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: mixPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = state
        job.error = error
        insertJobForTesting(job)
        return job.id
    }
}

/// Retrying a failed job by hand, and what the retry must not inherit from
/// the run that failed.
///
/// A failed job stays in the queue, and in the snapshot, until the user
/// dismisses it. Nothing ever ran it again, so the only way back was finding
/// the staged audio and importing it by hand, which is how the far end of a
/// recording that failed on an empty microphone track was recovered in the
/// field.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PipelineQueueRetryTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_queue_retry_test")
    }

    private func makeQueue(
        engine: MockEngine,
        diarization: MockDiarization? = nil,
        protocolGen: MockProtocolGen = MockProtocolGen(),
        outputDir: URL? = nil,
        terminalJobStore: TerminalJobStore? = nil,
    ) -> PipelineQueue {
        PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization ?? MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: outputDir ?? tmpDir,
            logDir: tmpDir,
            diarizeEnabled: diarization != nil,
            micLabel: "Me",
            terminalJobStore: terminalJobStore,
        )
    }

    /// An empty file at `name` in the temp dir. A retry needs the job's audio
    /// to exist, so every job a test expects to be retryable points at one.
    private func touch(_ name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    private func makeFailingEngine() -> MockEngine {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Recovered words")]
        engine.shouldThrow = true
        return engine
    }

    /// Runs one job to `.error` through the real pipeline and returns its ID.
    private func failOneJob(on queue: PipelineQueue, mixPath: URL) async throws -> UUID {
        let job = PipelineJob(
            meetingTitle: "Failed Call", appName: "Teams",
            mixPath: mixPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        await queue.awaitProcessing()
        let failed = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(failed.state, .error, "test premise: the first run failed")
        return job.id
    }

    // MARK: - Retry

    func testRetryingAFailedJobRunsItAgain() async throws {
        let engine = makeFailingEngine()
        let queue = makeQueue(engine: engine)
        let jobID = try await failOneJob(on: queue, mixPath: createTestAudioFile(in: tmpDir))

        // Whatever broke the first run is gone now, say an app update fixed it.
        engine.shouldThrow = false
        XCTAssertTrue(queue.retryJob(id: jobID))
        await queue.awaitProcessing()

        let retried = try XCTUnwrap(queue.jobs.first { $0.id == jobID })
        XCTAssertEqual(retried.state, .done, "the retry did not run the job to completion")
        XCTAssertNil(retried.error, "the first run's error outlived the retry that succeeded")
        XCTAssertEqual(engine.transcribeCallCount, 2, "the audio was not transcribed a second time")
    }

    /// The warnings describe the run that produced them. Carried into a retry,
    /// a failed run's "did not complete" would sit on a job that completed.
    func testRetryDropsTheFailedRunsWarnings() async throws {
        let engine = makeFailingEngine()
        let queue = makeQueue(engine: engine)
        let jobID = try await failOneJob(on: queue, mixPath: createTestAudioFile(in: tmpDir))
        queue.addWarning(id: jobID, "left over from the failed run")

        XCTAssertTrue(queue.retryJob(id: jobID))
        await queue.awaitProcessing()

        let retried = try XCTUnwrap(queue.jobs.first { $0.id == jobID })
        XCTAssertFalse(retried.warnings.contains("left over from the failed run"))
    }

    /// The per-run verdicts go with the error: each describes the run that
    /// failed, and the retry records its own. The audio paths are the retry's
    /// input and stay.
    func testPrepareForRetryDropsWhatTheFailedRunConcluded() {
        let mixPath = tmpDir.appendingPathComponent("kept_mix.wav")
        var job = PipelineJob(
            meetingTitle: "Failed Call", appName: "Teams",
            mixPath: mixPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .error
        job.error = "Invalid audio data provided"
        job.warnings = ["Microphone track was empty"]
        job.trackViability = .appOnly
        job.namingStartedAt = Date()
        job.echo = EchoDetectionDTO(EchoBleedDetector.Result(
            windowScores: [EchoBleedDetector.WindowScore(correlation: 0.9, lagSeconds: 0.015)],
        ))

        job.prepareForRetry()

        XCTAssertNil(job.error)
        XCTAssertTrue(job.warnings.isEmpty)
        XCTAssertNil(job.trackViability)
        XCTAssertNil(job.echo)
        XCTAssertNil(job.namingStartedAt, "a retry inherited the failed run's naming day")
        XCTAssertEqual(job.mixPath, mixPath)
    }

    /// Only a failed job is retried. Re-queueing a running job would run it
    /// twice, and re-queueing a finished one would redo work nobody asked for.
    func testRetryLeavesAJobThatHasNotFailedAlone() {
        let queue = PipelineQueue(logDir: tmpDir)
        for state in [JobState.waiting, .transcribing, .speakerNamingPending, .done] {
            let jobID = queue.insertJobForTesting(
                mixPath: tmpDir.appendingPathComponent("\(state.rawValue)_mix.wav"), state: state,
            )

            XCTAssertFalse(queue.canRetryJob(id: jobID), "offered a retry for a job in \(state)")
            XCTAssertFalse(queue.retryJob(id: jobID), "retried a job in \(state)")
            XCTAssertEqual(queue.jobs.first { $0.id == jobID }?.state, state)
        }
        XCTAssertFalse(queue.retryJob(id: UUID()), "retried a job that does not exist")
    }

    /// The field case: the job failed on the version that had the defect, the
    /// app was updated and relaunched, and the failed job came back from the
    /// snapshot. The retry must work there, and it must not depend on the
    /// processed-recordings ledger, which records every failed recording.
    func testAFailedJobRestoredAfterARelaunchCanBeRetried() async throws {
        let mixPath = try createTestAudioFile(in: tmpDir)
        let firstLaunch = makeQueue(engine: makeFailingEngine())
        let jobID = try await failOneJob(on: firstLaunch, mixPath: mixPath)
        await firstLaunch.awaitSnapshotFlush()
        XCTAssertTrue(
            ProcessedRecordingsLedger(logDir: tmpDir).load().contains(mixPath.standardizedFileURL.path),
            "test premise: the failure was recorded in the ledger",
        )

        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Recovered words")]
        let nextLaunch = makeQueue(engine: engine)
        nextLaunch.loadSnapshot()
        XCTAssertEqual(nextLaunch.jobs.first { $0.id == jobID }?.state, .error, "test premise: restored as failed")

        XCTAssertTrue(nextLaunch.retryJob(id: jobID))
        await nextLaunch.awaitProcessing()

        XCTAssertEqual(nextLaunch.jobs.first { $0.id == jobID }?.state, .done)
    }

    // MARK: - What a retry must not inherit from the failed run

    /// Diarization parks the naming state (the in-memory data that makes stage
    /// 3 skip the protocol and wait for the dialog, the sidecar JSON, the
    /// diarizer mode) before stage 3 writes the transcript, and that write can
    /// throw. A retry that produces no naming state of its own, here because
    /// the diarizer is unavailable this time, used to find the failed run's
    /// state still there, skip the protocol and park in the naming dialog with
    /// the old mapping.
    func testARetryDoesNotParkOnTheFailedRunsSpeakerNaming() async throws {
        let outputDir = tmpDir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        // A file where the protocols folder belongs makes saving the transcript
        // throw, after diarization has already parked its naming state.
        let blocker = outputDir.appendingPathComponent("protocols")
        try Data().write(to: blocker)
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello there")]
        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(
            engine: engine, diarization: diarization, protocolGen: protocolGen, outputDir: outputDir,
        )
        let jobID = try await failOneJob(on: queue, mixPath: createTestAudioFile(in: tmpDir))
        let failed = try XCTUnwrap(queue.jobs.first { $0.id == jobID })
        let store = SpeakerNamingStore(outputDir: outputDir)
        XCTAssertNotNil(queue.speakerNamingDataByJob[jobID], "test premise: the failed run parked naming data")
        XCTAssertTrue(store.hasNamingData(slug: failed.namingSlug), "test premise: the failed run wrote its sidecar")
        XCTAssertNotNil(failed.usedDiarizerMode, "test premise: the failed run recorded its diarizer mode")

        try FileManager.default.removeItem(at: blocker)
        diarization.isAvailable = false
        XCTAssertTrue(queue.retryJob(id: jobID))

        XCTAssertNil(queue.speakerNamingDataByJob[jobID], "the failed run's naming data outlived the retry")
        XCTAssertFalse(store.hasNamingData(slug: failed.namingSlug), "the failed run's naming sidecar outlived the retry")
        XCTAssertNil(queue.jobs.first { $0.id == jobID }?.usedDiarizerMode)

        await queue.awaitProcessing()
        XCTAssertEqual(
            queue.jobs.first { $0.id == jobID }?.state, .done,
            "the retry parked in the naming dialog on the failed run's speakers",
        )
        XCTAssertTrue(protocolGen.generateCalled, "the retry skipped the protocol")
    }

    /// The audio length feeds the stage-timing stats. The retry measures its
    /// own; one left from the failed run would be charged to stages the retry
    /// times.
    func testARetryForgetsTheFailedRunsAudioLength() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let jobID = try queue.insertJobForTesting(mixPath: touch("a_mix.wav"), state: .error, error: "Failed")
        queue.jobAudioSeconds[jobID] = 42

        XCTAssertTrue(queue.retryJob(id: jobID))

        XCTAssertNil(queue.jobAudioSeconds[jobID])
    }

    /// The automation API answers from the live job first and from the durable
    /// terminal record once the job is gone. A retried job that is then
    /// cancelled is gone without a new terminal record, so the old one, the
    /// error the retry was meant to replace, used to be served again.
    func testCancellingARetriedJobDoesNotBringBackItsOldError() async throws {
        let storePath = tmpDir.appendingPathComponent("terminal_jobs.json")
        let terminalJobs = TerminalJobStore(path: storePath)
        let queue = makeQueue(engine: makeFailingEngine(), terminalJobStore: terminalJobs)
        let jobID = try await failOneJob(on: queue, mixPath: createTestAudioFile(in: tmpDir))
        XCTAssertEqual(terminalJobs.lookup(jobID: jobID)?.state, .error, "test premise: the failure was recorded")

        XCTAssertTrue(queue.retryJob(id: jobID))
        queue.cancelJob(id: jobID)
        await queue.awaitProcessing()

        XCTAssertNil(terminalJobs.lookup(jobID: jobID), "the cancelled retry reads back as the old error")
        XCTAssertNil(TerminalJobStore(path: storePath).lookup(jobID: jobID), "the old error came back after a restart")
    }

    // MARK: - Two jobs, one recording

    private static let duplicateRunError = "This recording is already being processed"

    /// Two jobs for one recording would transcribe it twice and write two
    /// sets of outputs. Another job holding the audio, waiting, running or
    /// finished, means the recording is handled; a finished owner only stops
    /// blocking once it is gone from the queue.
    func testARetryIsRefusedWhileAnotherJobHoldsTheSameRecording() throws {
        let mixPath = try touch("shared_mix.wav")
        for ownerState in [JobState.waiting, .transcribing, .speakerNamingPending, .done] {
            let queue = PipelineQueue(logDir: tmpDir)
            let failedID = queue.insertJobForTesting(mixPath: mixPath, state: .error, error: "Failed")
            // Same file, spelled differently: the check compares standardized paths.
            queue.insertJobForTesting(
                mixPath: tmpDir.appendingPathComponent("./shared_mix.wav"), state: ownerState,
            )

            XCTAssertFalse(queue.canRetryJob(id: failedID), "offered a retry while the owner is \(ownerState)")
            XCTAssertFalse(queue.retryJob(id: failedID), "retried while the owner is \(ownerState)")
            XCTAssertEqual(queue.jobs.first { $0.id == failedID }?.state, .error)
        }
    }

    /// The same, when the run holding the audio belongs to another queue: the
    /// in-flight registry is shared across queue rebuilds, and a run claimed
    /// there is not in this queue's job list at all.
    func testARetryIsRefusedWhileARunElsewhereHoldsTheRecording() throws {
        let registry = InFlightRunRegistry()
        let mixPath = try touch("claimed_mix.wav")
        XCTAssertEqual(registry.begin(jobID: UUID(), mixPath: mixPath), .claimed, "test premise: the claim was free")
        let queue = PipelineQueue(logDir: tmpDir, inFlightRuns: registry)
        let failedID = queue.insertJobForTesting(mixPath: mixPath, state: .error, error: "Failed")

        XCTAssertFalse(queue.canRetryJob(id: failedID))
        XCTAssertFalse(queue.retryJob(id: failedID), "retried a recording another queue is running")
        XCTAssertEqual(queue.jobs.first { $0.id == failedID }?.state, .error)
    }

    /// A job refused because another run held its audio is only a duplicate
    /// for as long as that run holds it. The owner releases the audio when it
    /// ends, and if it ends in failure nothing processes the recording any
    /// more; the duplicate must be retryable then, or neither job can be.
    func testADuplicateWhoseOwnerFailedCanBeRetried() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let mixPath = try touch("dup_mix.wav")
        queue.insertJobForTesting(mixPath: mixPath, state: .error)
        let duplicateID = queue.insertJobForTesting(mixPath: mixPath, state: .error, error: Self.duplicateRunError)

        XCTAssertTrue(queue.canRetryJob(id: duplicateID))
        XCTAssertTrue(queue.retryJob(id: duplicateID), "the duplicate stayed unretryable after its owner failed")
    }

    /// Likewise once the owner is gone, cancelled or dismissed.
    func testADuplicateWhoseOwnerIsGoneCanBeRetried() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let mixPath = try touch("dup_mix.wav")
        let ownerID = queue.insertJobForTesting(mixPath: mixPath, state: .waiting)
        let duplicateID = queue.insertJobForTesting(mixPath: mixPath, state: .error, error: Self.duplicateRunError)
        XCTAssertFalse(queue.canRetryJob(id: duplicateID), "test premise: refused while the owner holds the audio")

        queue.cancelJob(id: ownerID)

        XCTAssertTrue(queue.canRetryJob(id: duplicateID))
        XCTAssertTrue(queue.retryJob(id: duplicateID), "the duplicate stayed unretryable after its owner went")
    }

    /// A retry runs on the job's audio, so there is nothing to retry once it
    /// is gone. The case that matters: a duplicate whose owner's stage 3 moved
    /// the staged recording into the output folder. The two jobs then name
    /// different paths, so the hold check cannot see the owner any more, and
    /// the duplicate's staging path names a file that no longer exists.
    func testARetryIsRefusedWhenTheAudioIsGone() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let relocated = try touch("relocated_mix.wav")
        queue.insertJobForTesting(mixPath: relocated, state: .speakerNamingPending)
        let duplicateID = queue.insertJobForTesting(
            mixPath: tmpDir.appendingPathComponent("moved_away_mix.wav"),
            state: .error, error: Self.duplicateRunError,
        )

        XCTAssertFalse(queue.canRetryJob(id: duplicateID), "offered a retry on audio that is gone")
        XCTAssertFalse(queue.retryJob(id: duplicateID))
    }

    /// The registry holds a run by its job ID as well as its audio, and a run
    /// without a mix file is held by the ID alone. The job's own run still
    /// being claimed means it has not finished, whatever the list says.
    func testARetryIsRefusedWhileTheJobsOwnRunIsClaimed() throws {
        let registry = InFlightRunRegistry()
        let queue = PipelineQueue(logDir: tmpDir, inFlightRuns: registry)
        let failedID = try queue.insertJobForTesting(mixPath: touch("own_mix.wav"), state: .error, error: "Failed")
        XCTAssertEqual(registry.begin(jobID: failedID, mixPath: nil), .claimed, "test premise: the claim was free")

        XCTAssertFalse(queue.canRetryJob(id: failedID), "offered a retry while the job's own run is claimed")
    }

    /// The restore marks a job interrupted mid-protocol so its next run only
    /// generates the protocol. That marking is peeked, not consumed, when the
    /// transcript turns out unreadable; the full run that follows can then
    /// fail with the marking still there, and a retry would take it and
    /// publish the failed run's undiarized draft as the protocol.
    func testARetryDropsAPendingProtocolResume() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let jobID = try queue.insertJobForTesting(mixPath: touch("resume_mix.wav"), state: .error, error: "Failed")
        queue.protocolResumeDispositions[jobID] = .resumeProtocolOnly

        XCTAssertTrue(queue.retryJob(id: jobID))

        XCTAssertNil(queue.protocolResumeDispositions[jobID], "the retry kept the failed run's protocol-only resume")
    }

    /// Naming data is written under the output folder of the queue that ran
    /// diarization. A retry after a rebuild with another output folder has to
    /// clean up where it was written, not where the setting points today.
    func testARetryRemovesNamingDataFromTheFolderItWasWrittenTo() async throws {
        let firstDir = tmpDir.appendingPathComponent("first_out")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        // Saving the transcript throws after diarization wrote its naming data.
        try Data().write(to: firstDir.appendingPathComponent("protocols"))
        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello there")]
        let firstQueue = makeQueue(engine: engine, diarization: diarization, outputDir: firstDir)
        let jobID = try await failOneJob(on: firstQueue, mixPath: createTestAudioFile(in: tmpDir))
        let slug = try XCTUnwrap(firstQueue.jobs.first { $0.id == jobID }?.namingSlug)
        XCTAssertTrue(
            SpeakerNamingStore(outputDir: firstDir).hasNamingData(slug: slug),
            "test premise: the failed run wrote naming data",
        )
        await firstQueue.awaitSnapshotFlush()

        let secondDir = tmpDir.appendingPathComponent("second_out")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let rebuilt = makeQueue(engine: makeFailingEngine(), outputDir: secondDir)
        rebuilt.loadSnapshot()
        XCTAssertTrue(rebuilt.retryJob(id: jobID))
        await rebuilt.awaitProcessing()

        XCTAssertFalse(
            SpeakerNamingStore(outputDir: firstDir).hasNamingData(slug: slug),
            "the failed run's naming data stayed in the folder it was written to",
        )
    }
}
