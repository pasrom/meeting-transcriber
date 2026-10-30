@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The naming dialog only ever offers a job that takes answers, and an answer
/// the session refuses leaves the dialog usable and says why.
@MainActor
final class NamingAnswerTests: XCTestCase {
    // MARK: - Answer gate

    func testARefusedAnswerKeepsTheDialogAnswerableAndSaysWhy() {
        var gate = NamingAnswerGate()
        let job = UUID()

        XCTAssertTrue(gate.submit(jobID: job) { "Re-run is not possible" })
        XCTAssertEqual(gate.refusalMessage, "Re-run is not possible")

        var delivered = false
        XCTAssertTrue(gate.submit(jobID: job) {
            delivered = true
            return nil
        })
        XCTAssertTrue(delivered, "the answer after a refused one was swallowed")
        XCTAssertNil(gate.refusalMessage, "a taken answer left the old reason up")
    }

    func testATakenAnswerIsHandedOverOncePerJob() {
        var gate = NamingAnswerGate()
        let job = UUID()
        var deliveries = 0

        gate.submit(jobID: job) {
            deliveries += 1
            return nil
        }
        gate.submit(jobID: job) {
            deliveries += 1
            return nil
        }
        gate.submit(jobID: UUID()) {
            deliveries += 1
            return nil
        }

        XCTAssertEqual(deliveries, 2, "a second answer for the same job went through, or the next job's did not")
    }

    // MARK: - Dialog wiring

    func testReRunHandsItsAnswerToTheRefusableHost() throws {
        var answers: [PipelineQueue.SpeakerNamingResult] = []
        let view = SpeakerNamingView.answering(
            data: PipelineQueue.SpeakerNamingData(
                jobID: UUID(), meetingTitle: "Standup", mapping: ["SPEAKER_00": "SPEAKER_00"],
                speakingTimes: ["SPEAKER_00": 60], embeddings: [:], audioPath: nil,
                segments: [], participants: [], isDualSource: false,
            ),
            gracePeriod: 0,
        ) { result in
            answers.append(result)
            return SpeakerNamingRefusal.rerunAudioMissing.message
        }

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.rerunButton).button().tap()

        guard case .rerun = answers.first else {
            XCTFail("Re-run handed over \(answers)")
            return
        }
    }

    /// The dialog says why the last re-run came back with nothing.
    func testTheDialogShowsTheNoticeItIsGiven() throws {
        let view = SpeakerNamingView.answering(
            data: PipelineQueue.SpeakerNamingData(
                jobID: UUID(), meetingTitle: "Standup", mapping: ["SPEAKER_00": "SPEAKER_00"],
                speakingTimes: ["SPEAKER_00": 60], embeddings: [:], audioPath: nil,
                segments: [], participants: [], isDualSource: false,
            ),
            gracePeriod: 0,
            notice: SpeakerNamingRefusal.rerunFailed.message,
        ) { _ in nil }

        let text = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.namingRefusalMessage).text()
        XCTAssertEqual(try text.string(), SpeakerNamingRefusal.rerunFailed.message)
    }

    // MARK: - A re-run that comes back with nothing

    /// A re-run that finds no voices puts the job back with its old naming and
    /// says so, rather than reopening the dialog as if nothing had happened.
    func testARerunThatFindsNoVoicesSaysSo() async throws {
        let (queue, diarizer, jobID) = try await makeJobAwaitingNaming()
        diarizer.resultToReturn = Self.diarization(withEmbeddings: false)

        try await rerun(jobID, in: queue)

        XCTAssertEqual(queue.jobs.first { $0.id == jobID }?.state, .speakerNamingPending)
        XCTAssertEqual(queue.lateRerunFailure(forJobID: jobID), .rerunFoundNoVoices)
    }

    /// The same for a re-run that fails, and the next answer the session takes
    /// clears the reason.
    func testARerunThatFailsSaysSoUntilTheNextAnswer() async throws {
        let (queue, diarizer, jobID) = try await makeJobAwaitingNaming()
        diarizer.throwOnPathSuffix = SpeakerNamingStore.mixSuffix

        try await rerun(jobID, in: queue)
        XCTAssertEqual(queue.lateRerunFailure(forJobID: jobID), .rerunFailed)

        XCTAssertNil(queue.completeSpeakerNaming(jobID: jobID, result: .skipped))
        XCTAssertNil(queue.lateRerunFailure(forJobID: jobID))
    }

    private static func diarization(withEmbeddings: Bool) -> DiarizationResult {
        DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5], autoNames: [:],
            embeddings: withEmbeddings ? ["SPEAKER_0": [1, 0, 0]] : nil,
        )
    }

    private func makeJobAwaitingNaming() async throws -> (PipelineQueue, MockDiarization, UUID) {
        let dir = try makeTempDirectory(prefix: "naming_rerun_failure")
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let diarizer = MockDiarization()
        diarizer.resultToReturn = Self.diarization(withEmbeddings: true)
        let queue = PipelineQueue(
            engine: engine, diarizationFactory: { diarizer }, protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir, logDir: dir, stagingDir: dir.appendingPathComponent("staging"),
            diarizeEnabled: true, inFlightRuns: InFlightRunRegistry(),
        )
        let job = try PipelineJob(
            meetingTitle: "Standup", appName: "Teams", mixPath: createTestAudioFile(in: dir),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.jobs.first?.state, .speakerNamingPending, "test premise")
        return (queue, diarizer, job.id)
    }

    private func rerun(_ jobID: UUID, in queue: PipelineQueue) async throws {
        XCTAssertNil(queue.completeSpeakerNaming(jobID: jobID, result: .rerun(2)), "test premise: the re-run started")
        let tasks = try XCTUnwrap(queue.naming.lateWork[jobID]?.values)
        for task in tasks {
            await task.value
        }
    }

    // MARK: - Which job the window shows

    /// A selection can outlive its job's naming state: a re-run moves the job to
    /// `.diarizing`, and the window reopens when another job reaches naming.
    /// The window then shows the job that is waiting, not the stale one, whose
    /// answers the session would drop.
    func testTheWindowNeverShowsAJobThatIsNotAwaitingNaming() throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "naming_window"))
        var rerunning = PipelineJob(
            meetingTitle: "A", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        rerunning.state = .diarizing
        var waiting = PipelineJob(
            meetingTitle: "B", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        waiting.state = .speakerNamingPending
        for job in [rerunning, waiting] {
            queue.insertJobForTesting(job)
            queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
                jobID: job.id, meetingTitle: job.meetingTitle, mapping: [:], speakingTimes: [:],
                embeddings: [:], audioPath: nil, segments: [], participants: [], isDualSource: false,
            )
        }

        XCTAssertEqual(queue.namingJobID(preferring: rerunning.id), waiting.id)
        XCTAssertEqual(queue.speakerNamingData(forJobID: rerunning.id)?.jobID, waiting.id)

        queue.updateJobState(id: waiting.id, to: .done)
        XCTAssertNil(queue.speakerNamingData(forJobID: rerunning.id), "with nothing waiting the window has nothing to show")
    }

    /// Opening the window pins the job it shows. Unpinned, a job earlier in the
    /// queue reaching naming switched the window under the user.
    func testOpeningTheWindowPinsTheJobItShows() throws {
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "naming_pin"))
        let appState = try makeIsolatedAppState(initialQueue: queue)
        let shown = pendingJob("Shown", in: queue)
        queue.insertJobForTesting(shown)

        appState.pinShownNamingJob()
        let earlier = pendingJob("Earlier", in: queue)
        queue.jobs.insert(earlier, at: 0)

        XCTAssertEqual(
            queue.speakerNamingData(forJobID: appState.selectedNamingJobID)?.jobID, shown.id,
            "a job reaching naming switched the open window",
        )
    }

    /// A job awaiting naming, with naming data stashed in `queue`'s session.
    private func pendingJob(_ title: String, in queue: PipelineQueue) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: title, appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
            jobID: job.id, meetingTitle: title, mapping: [:], speakingTimes: [:],
            embeddings: [:], audioPath: nil, segments: [], participants: [], isDualSource: false,
        )
        return job
    }

    /// After Skip the window moves on to the next waiting job. A skipped job
    /// used to stay awaiting naming, with its naming data already gone, until
    /// its protocol task first ran, and the window stayed on it with nothing
    /// to show.
    func testAfterSkipTheWindowMovesOnToTheNextJob() throws {
        let dir = try makeTempDirectory(prefix: "naming_skip")
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() }, outputDir: dir, logDir: dir,
            stagingDir: dir.appendingPathComponent("staging"), inFlightRuns: InFlightRunRegistry(),
        )
        var ids: [UUID] = []
        for title in ["A", "B"] {
            let transcript = dir.appendingPathComponent("\(title).txt")
            try "[00:00] SPEAKER_0: hello".write(to: transcript, atomically: true, encoding: .utf8)
            var job = PipelineJob(
                meetingTitle: title, appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
            )
            job.state = .speakerNamingPending
            job.transcriptPath = transcript
            queue.insertJobForTesting(job)
            queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
                jobID: job.id, meetingTitle: title, mapping: ["SPEAKER_0": "SPEAKER_0"], speakingTimes: [:],
                embeddings: [:], audioPath: nil, segments: [], participants: [], isDualSource: false,
            )
            ids.append(job.id)
        }

        XCTAssertNil(queue.completeSpeakerNaming(jobID: ids[0], result: .skipped))

        XCTAssertEqual(queue.namingJobID(preferring: nil), ids[1], "the window stayed on the skipped job")
    }
}
