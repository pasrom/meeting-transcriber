@testable import MeetingTranscriber
import XCTest

/// A cancelled job writes nothing further: no naming data or sidecar, no
/// transcript, no relocated recording, no protocol, no naming window, and no
/// LLM call once the cancellation is seen.
///
/// Cancelling a job stops its task, but a step that ignores cancellation still
/// returns, and one that honours it can be caught on the way out like any
/// failure. Both used to carry the job's work on past the cancel.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class CancelledJobWritesNothingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "cancelled_job_writes_nothing")
    }

    // MARK: - Main pipeline

    /// A diarizer that honours the cancellation throws, and that must end the
    /// run rather than read as a diarization failure that stage 3 carries on
    /// from.
    func testACancelDuringDiarizationEndsTheRunBeforeStageThree() async throws {
        let diarizer = GatedDiarization(result: Self.diarization(withEmbeddings: false), honoursCancellation: true)
        let generator = MockProtocolGen()
        let queue = makeQueue(diarizer: diarizer, generator: generator)
        diarizer.parkNextRun()
        let job = try makeJob()
        queue.enqueue(job)
        await waitFor { await diarizer.gate.hasWaiter }

        queue.cancelJob(id: job.id)
        await diarizer.gate.open()
        await waitFor(!queue.isProcessing, timeout: .seconds(10))

        XCTAssertFalse(generator.generateCalled, "a protocol was asked for a cancelled job")
        XCTAssertEqual(files(endingIn: ".md"), [], "a protocol was saved for a cancelled job")
        XCTAssertEqual(files(in: "recordings"), [], "stage 3 moved audio for a cancelled job")
        let transcript = try XCTUnwrap(files(endingIn: ".txt").first, "test premise: the draft was saved")
        XCTAssertFalse(
            try String(contentsOf: protocolsDir.appendingPathComponent(transcript), encoding: .utf8)
                .contains("SPEAKER_0"),
            "stage 3 rewrote the transcript for a cancelled job",
        )
    }

    /// A diarizer that ignores the cancellation returns its result as if
    /// nothing happened. The job is gone by then, so it gets no naming data, no
    /// sidecar, no naming window and no naming handler.
    func testADiarizerIgnoringTheCancelLeavesNoNamingBehind() async throws {
        let diarizer = GatedDiarization(result: Self.diarization(withEmbeddings: true))
        let generator = MockProtocolGen()
        let queue = makeQueue(diarizer: diarizer, generator: generator)
        var handlerCalls = 0
        queue.speakerNamingHandler = { _ in
            handlerCalls += 1
            return .skipped
        }
        let windowPosts = NotificationCounter(.showSpeakerNaming)
        diarizer.parkNextRun()
        let job = try makeJob()
        queue.enqueue(job)
        await waitFor { await diarizer.gate.hasWaiter }

        queue.cancelJob(id: job.id)
        await diarizer.gate.open()
        await waitFor(!queue.isProcessing, timeout: .seconds(10))

        XCTAssertNil(queue.speakerNamingDataByJob[job.id], "naming data was stored for a cancelled job")
        XCTAssertEqual(files(endingIn: SpeakerNamingStore.namingJSONSuffix), [], "a naming sidecar was written")
        XCTAssertEqual(windowPosts.count, 0, "the naming window was popped for a cancelled job")
        XCTAssertEqual(handlerCalls, 0, "the naming handler was asked about a cancelled job")
        XCTAssertNil(queue.naming.lateWork[job.id], "late work was started for a cancelled job")
        XCTAssertFalse(generator.generateCalled)
    }

    /// An engine that ignores the cancellation still returns its segments.
    /// The stage that follows must not run for the job: no draft transcript,
    /// no diarization.
    func testATranscriptionThatIgnoresTheCancelWritesNoDraft() async throws {
        let engine = ParkedEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let diarizer = MockDiarization()
        let queue = PipelineQueue(
            engine: engine, diarizationFactory: { diarizer }, protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir, logDir: tmpDir, stagingDir: stagingDir, diarizeEnabled: true,
            inFlightRuns: InFlightRunRegistry(),
        )
        let job = try makeJob()
        queue.enqueue(job)
        await waitFor(engine.isParked, timeout: .seconds(5))

        queue.cancelJob(id: job.id)
        engine.release()
        await waitFor(!queue.isProcessing, timeout: .seconds(10))

        XCTAssertEqual(files(endingIn: ".txt"), [], "a draft transcript was written for a cancelled job")
        XCTAssertEqual(diarizer.runCount, 0, "a cancelled job was diarized")
        XCTAssertNil(queue.jobAudioSeconds[job.id], "the cancel's cleared bookkeeping was written back")
    }

    // MARK: - The recording of a cancelled job

    /// The recording is the user's data. A cancelled job's staged recording
    /// moves to the output folder like a finished job's would, and nothing
    /// else of the job is written there.
    func testACancelledJobsRecordingMovesToTheOutputFolderAndNothingElse() async throws {
        let diarizer = GatedDiarization(result: Self.diarization(withEmbeddings: true))
        let queue = makeQueue(diarizer: diarizer, generator: MockProtocolGen())
        diarizer.parkNextRun()
        let job = try makeStagedJob()
        let staged = try XCTUnwrap(job.mixPath)
        queue.enqueue(job)
        await waitFor { await diarizer.gate.hasWaiter }

        queue.cancelJob(id: job.id)
        await queue.lastRecordingRelocation?.value
        await diarizer.gate.open()
        await waitFor(!queue.isProcessing, timeout: .seconds(10))

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "the recording stayed in staging")
        XCTAssertTrue(queue.processedLedger.load().contains(staged.standardizedFileURL.path), "the cancel did not hold")
        let recordings = files(in: "recordings")
        XCTAssertEqual(recordings.count, 1, "\(recordings)")
        XCTAssertTrue(recordings.allSatisfy { $0.hasSuffix(RecordingFileSuffix.mix) }, "\(recordings)")
        XCTAssertEqual(files(endingIn: ".md"), [])
        XCTAssertEqual(files(endingIn: SpeakerNamingStore.namingJSONSuffix), [])
    }

    /// A file the user picked for import is theirs and stays where it is.
    func testACancelledImportLeavesItsSourceUntouched() async throws {
        let diarizer = GatedDiarization(result: Self.diarization(withEmbeddings: false))
        let queue = makeQueue(diarizer: diarizer, generator: MockProtocolGen())
        diarizer.parkNextRun()
        let job = try makeJob()
        let source = try XCTUnwrap(job.mixPath)
        let before = try Data(contentsOf: source)
        queue.enqueue(job)
        await waitFor { await diarizer.gate.hasWaiter }

        queue.cancelJob(id: job.id)
        await queue.lastRecordingRelocation?.value
        await diarizer.gate.open()
        await waitFor(!queue.isProcessing, timeout: .seconds(10))

        XCTAssertEqual(try Data(contentsOf: source), before, "the imported file was moved or changed")
        XCTAssertEqual(files(in: "recordings"), [])
    }

    /// Orphan recovery does not offer an unmarked recording, it enqueues and
    /// processes it. While the move of a cancelled recording has not landed
    /// (a slow copy to another volume, here one that cannot land at all), a
    /// scan, as a watch start's queue rebuild runs, must not bring the
    /// cancelled meeting back.
    func testAScanBeforeTheMoveLandedBringsNothingBack() async throws {
        try Data([0]).write(to: tmpDir.appendingPathComponent("recordings"))
        let queue = try await cancelStagedJobMidDiarization()

        await queue.recoverOrphanedRecordings(recordingsDir: stagingDir)

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), [], "the cancelled meeting was queued again")
        await queue.lastRecordingRelocation?.value
    }

    /// A move that failed leaves the recording in staging, where the next
    /// launch's recovery finds it: marked processed at the cancel, so it stays
    /// there, never deleted and never processed again.
    func testAFailedMoveLeavesTheRecordingInStagingAndOutOfTheQueue() async throws {
        try Data([0]).write(to: tmpDir.appendingPathComponent("recordings"))
        let queue = try await cancelStagedJobMidDiarization()
        await queue.lastRecordingRelocation?.value
        let staged = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: stagingDir.path).first { $0.hasSuffix(".wav") },
        )

        let nextLaunch = PipelineQueue(logDir: tmpDir, stagingDir: stagingDir)
        await nextLaunch.recoverOrphanedRecordings(recordingsDir: stagingDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDir.appendingPathComponent(staged).path))
        XCTAssertEqual(nextLaunch.jobs.map(\.meetingTitle), [], "the cancelled meeting was queued again")
    }

    /// A cross-volume copy that fails leaves nothing in the destination folder.
    func testAFailedCopyLeavesNoPartialBehind() throws {
        // A folder with an unreadable file in it: the copy starts, creating the
        // `.partial`, and fails on the way.
        let source = tmpDir.appendingPathComponent("source_bundle")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let locked = source.appendingPathComponent("locked.wav")
        try Data([1]).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let out = tmpDir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try PipelineQueue.moveIntoPlace(source, to: out.appendingPathComponent("meeting_mix.wav"), asIfAcrossVolumes: true),
        )

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "the failed copy left files behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source was touched")
    }

    /// A queue whose staged job was cancelled while it was diarized.
    private func cancelStagedJobMidDiarization() async throws -> PipelineQueue {
        let diarizer = GatedDiarization(result: Self.diarization(withEmbeddings: false))
        let queue = makeQueue(diarizer: diarizer, generator: MockProtocolGen())
        diarizer.parkNextRun()
        let job = try makeStagedJob()
        queue.enqueue(job)
        await waitFor { await diarizer.gate.hasWaiter }
        queue.cancelJob(id: job.id)
        await diarizer.gate.open()
        await waitFor(!queue.isProcessing, timeout: .seconds(10))
        return queue
    }

    /// Across volumes a move is a copy. The copy is built under a hidden
    /// `.partial` name and only renamed into place when complete, so a copy cut
    /// short never sits under a recording's name; the source goes last.
    func testACopyAcrossVolumesOnlyEverNamesACompleteFile() throws {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let source = try createTestAudioFile(in: stagingDir)
        let expected = try Data(contentsOf: source)
        let destination = tmpDir.appendingPathComponent("out/meeting_mix.wav")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        // A stale half copy from an earlier attempt that was cut short.
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".meeting_mix.wav.partial")
        try Data([1, 2, 3]).write(to: partial)

        try PipelineQueue.moveIntoPlace(source, to: destination, asIfAcrossVolumes: true)

        XCTAssertEqual(try Data(contentsOf: destination), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the source outlived a complete copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "the half copy was left behind")
    }

    /// A failed job keeps its recording for Retry, so it holds the audio as
    /// much as a running one does.
    func testCancellingAJobLeavesTheRecordingAFailedJobKeepsForRetry() async throws {
        let queue = makeQueue(diarizer: MockDiarization(), generator: MockProtocolGen())
        let job = try makeStagedJob()
        let staged = try XCTUnwrap(job.mixPath)
        var failed = PipelineJob(
            meetingTitle: "Failed", appName: "Teams", mixPath: staged, appPath: nil, micPath: nil, micDelay: 0,
        )
        failed.state = .error
        queue.insertJobForTesting(failed)
        queue.insertJobForTesting(job)

        queue.cancelJob(id: job.id)
        await queue.lastRecordingRelocation?.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "the failed job's recording was moved away")
    }

    /// Two jobs can point at the same staged recording (a recovered orphan,
    /// or a re-import of the staged file next to the original). Cancelling one
    /// must not move the audio out from under the other.
    func testCancellingADuplicateLeavesTheRecordingAnotherJobUses() async throws {
        let engine = ParkedEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let queue = PipelineQueue(
            engine: engine, diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir, logDir: tmpDir, stagingDir: stagingDir, inFlightRuns: InFlightRunRegistry(),
        )
        let running = try makeStagedJob()
        let staged = try XCTUnwrap(running.mixPath)
        queue.enqueue(running)
        await waitFor(engine.isParked, timeout: .seconds(5))
        let duplicate = PipelineJob(
            meetingTitle: "Duplicate", appName: "Teams", mixPath: staged, appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.insertJobForTesting(duplicate)

        queue.cancelJob(id: duplicate.id)
        await queue.lastRecordingRelocation?.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "the running job's recording was moved away")
        engine.release()
        await queue.awaitProcessing()
    }

    // MARK: - Late paths

    /// The late confirm rewrites the transcript and then asks for the protocol.
    /// Cancelled while the model writes, the job gets no protocol file.
    func testALateConfirmCancelledDuringItsProtocolSavesNone() async throws {
        try await assertCancelledDuringLateProtocolSavesNone(.confirmed(["SPEAKER_0": "Alice"]))
    }

    /// Accepting the auto-names generates the protocol on a late task too.
    func testAcceptingAutoNamesCancelledDuringTheProtocolSavesNone() async throws {
        try await assertCancelledDuringLateProtocolSavesNone(.skipped)
    }

    private func assertCancelledDuringLateProtocolSavesNone(
        _ result: PipelineQueue.SpeakerNamingResult,
        file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        let generator = ParkingProtocolGen()
        let diarizer = GatedDiarization(result: Self.diarization(withEmbeddings: true))
        let queue = makeQueue(diarizer: diarizer, generator: generator)
        let job = try makeJob()
        queue.enqueue(job)
        await waitFor(!queue.isProcessing, timeout: .seconds(10))
        XCTAssertEqual(queue.jobs.first?.state, .speakerNamingPending, "test premise", file: file, line: line)

        generator.parkNextCall()
        queue.completeSpeakerNaming(jobID: job.id, result: result)
        await waitFor(generator.isParked, timeout: .seconds(5))
        let late = try XCTUnwrap(queue.naming.lateWork[job.id]?.values, "test premise", file: file, line: line)

        queue.cancelJob(id: job.id)
        await generator.gate.open()
        for task in late {
            await task.value
        }

        XCTAssertEqual(generator.callCount, 1, "test premise", file: file, line: line)
        XCTAssertEqual(files(endingIn: ".md"), [], "a protocol was saved for a cancelled job", file: file, line: line)
    }

    /// A late confirm that outlives its job must not clean up after it either.
    /// With the job gone its sidecar folders can no longer be read off it, and
    /// the cleanup fell back to the session's current folder, which after the
    /// output folder was repointed belongs to other meetings.
    func testALateConfirmCancelledAfterARepointDeletesNothingInTheNewFolder() async throws {
        let oldRoot = tmpDir.appendingPathComponent("old")
        let newRoot = tmpDir.appendingPathComponent("new")
        let slug = "meeting"
        for root in [oldRoot, newRoot] {
            let recordings = root.appendingPathComponent("recordings")
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            for suffix in [SpeakerNamingStore.namingJSONSuffix] + SpeakerNamingStore.sidecarSuffixes {
                try Data("x".utf8).write(to: recordings.appendingPathComponent("\(slug)\(suffix)"))
            }
        }
        let transcript = oldRoot.appendingPathComponent("protocols/\(slug).txt")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try "[00:00] SPEAKER_0: Hello".write(to: transcript, atomically: true, encoding: .utf8)

        let generator = ParkingProtocolGen()
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: newRoot, logDir: tmpDir, stagingDir: stagingDir, inFlightRuns: InFlightRunRegistry(),
        )
        var job = try makeJob()
        job.state = .speakerNamingPending
        job.namingSlug = slug
        job.transcriptPath = transcript
        job.recordSidecarOutputDir(oldRoot)
        queue.insertJobForTesting(job)
        queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
            jobID: job.id, meetingTitle: job.meetingTitle, mapping: ["SPEAKER_0": "SPEAKER_0"],
            speakingTimes: ["SPEAKER_0": 5], embeddings: [:], audioPath: nil, segments: [],
            participants: [], isDualSource: false,
        )

        generator.parkNextCall()
        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))
        await waitFor(generator.isParked, timeout: .seconds(5))
        let late = try XCTUnwrap(queue.naming.lateWork[job.id]?.values, "test premise")
        queue.cancelJob(id: job.id)
        await generator.gate.open()
        for task in late {
            await task.value
        }

        let left = (try? FileManager.default.contentsOfDirectory(
            atPath: newRoot.appendingPathComponent("recordings").path,
        )) ?? []
        XCTAssertEqual(left.count, 1 + SpeakerNamingStore.sidecarSuffixes.count, "deleted in the new folder: \(left)")
    }

    // MARK: - Fixture

    private var protocolsDir: URL {
        tmpDir.appendingPathComponent("protocols")
    }

    /// The app's own staging folder for these tests, never the real one.
    private var stagingDir: URL {
        tmpDir.appendingPathComponent("staging")
    }

    /// A job whose recording the app made itself, in its staging folder.
    /// Named like a recording the app staged (`<stamp>_mix.wav`), so orphan
    /// recovery treats it as one.
    private func makeStagedJob() throws -> PipelineJob {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let mix = stagingDir.appendingPathComponent("20261030_120000\(RecordingFileSuffix.mix)")
        try FileManager.default.moveItem(at: createTestAudioFile(in: stagingDir), to: mix)
        return PipelineJob(
            meetingTitle: "Cancelled", appName: "Teams",
            mixPath: mix, appPath: nil, micPath: nil, micDelay: 0,
        )
    }

    private static func diarization(withEmbeddings: Bool) -> DiarizationResult {
        DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: withEmbeddings ? ["SPEAKER_0": [1, 0, 0]] : nil,
        )
    }

    private func makeQueue(diarizer: any DiarizationProvider, generator: any ProtocolGenerating) -> PipelineQueue {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        return PipelineQueue(
            engine: engine,
            diarizationFactory: { diarizer },
            diarizationFactoryWithMode: nil,
            protocolGeneratorFactory: { generator },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: stagingDir,
            diarizeEnabled: true,
            numSpeakers: 0,
            micLabel: "Me",
            inFlightRuns: InFlightRunRegistry(),
        )
    }

    private func makeJob() throws -> PipelineJob {
        // The audio sits outside the staging folder, so stage 3 would leave it
        // in place: anything under `recordings/` is stage 3's own writing.
        let audio = tmpDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        return try PipelineJob(
            meetingTitle: "Cancelled", appName: "Teams",
            mixPath: createTestAudioFile(in: audio),
            appPath: nil, micPath: nil, micDelay: 0,
        )
    }

    private func files(in subfolder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent(subfolder).path)) ?? []
    }

    private func files(endingIn suffix: String) -> [String] {
        let all = FileManager.default.enumerator(at: tmpDir, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        return all.filter { $0.hasSuffix(suffix) }
    }
}

/// Counts posts of one notification for as long as it lives.
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var posts = 0
    private var token: (any NSObjectProtocol)?

    init(_ name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            lock.withLock { posts += 1 }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    var count: Int {
        lock.withLock { posts }
    }
}
