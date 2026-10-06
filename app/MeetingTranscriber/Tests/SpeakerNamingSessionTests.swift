@testable import MeetingTranscriber
import XCTest

/// Focused unit tests for `SpeakerNamingSession` exercised directly against a
/// mock delegate — no `PipelineQueue` construction needed, which is the whole
/// point of the extraction. Covers delegate wiring, the synchronous
/// `.speakerNamingPending → .generatingProtocol` transition (the RPC idempotency
/// contract), the skip flow, and that a deallocated delegate degrades operations
/// to no-ops instead of crashing.
@MainActor
final class SpeakerNamingSessionTests: XCTestCase {
    // MARK: - Echo quarantine

    /// Drives the real confirm path, because the pure filter being correct is
    /// only half the claim: the other half is that this is the code path a
    /// confirmation actually takes, from the dialog and from the automation API
    /// alike. Both reach `reapplySpeakerNames`.
    func testConfirmOnAnEchoAffectedRecordingWithholdsTheMicrophoneVoice() async throws {
        let tmp = try makeTempDirectory(prefix: "SpeakerNamingSessionTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] R_SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = NamingSessionFixture.session(outputDir: tmp)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock

        let job = NamingSessionFixture.pendingJob(
            namingSlug: "standup_abcd1234", transcriptPath: transcriptPath,
            echo: EchoDetectionDTO(NamingSessionFixture.echoResult(correlations: [0.9, 0.9, 0.9, 0.9])),
        )
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.dualTrackNamingData(jobID: job.id)

        let local = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded
        let remote = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
        session.completeSpeakerNaming(
            jobID: job.id,
            result: .confirmed([remote: "Speaker A", local: "Speaker B"]),
            source: .dialog,
        )

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        let written = try XCTUnwrap(mock.updateSpeakerDBEmbeddings.first)
        XCTAssertNil(
            written[local],
            "The microphone track of an affected recording carries the remote voice too; its embedding must never reach the speaker DB, which has no rollback",
        )
        XCTAssertEqual(
            written[remote],
            [1, 0, 0],
            "The app track is upstream of the bleed, so a remote participant named here is still learned",
        )
    }

    /// The protocol belongs beside the transcript it was made from, which sits
    /// under the folder the job recorded. This session's folder is wherever the
    /// output setting points now, so after a repoint a late confirm wrote the
    /// protocol into one folder while its transcript stayed in another.
    func testLateConfirmWritesTheProtocolUnderTheFolderTheJobRecorded() async throws {
        let recorded = try makeTempDirectory(prefix: "LateConfirmRecorded")
        let current = try makeTempDirectory(prefix: "LateConfirmCurrent")
        let transcriptPath = recorded.appendingPathComponent("protocols/standup.txt")
        try FileManager.default.createDirectory(
            at: transcriptPath.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try "] R_SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = NamingSessionFixture.session(outputDir: current)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock
        var job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
        job.recordSidecarOutputDir(recorded)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

        session.completeSpeakerNaming(
            jobID: job.id, result: .confirmed(["SPEAKER_0": "Speaker A"]), source: .dialog,
        )

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        XCTAssertEqual(
            mock.generateProtocolCalls.map(\.protocolsDir),
            [recorded.appendingPathComponent("protocols")],
        )
    }

    /// The echo evidence is the persisted app track, and it sits under the
    /// folder the job recorded. Read from this session's folder instead it is
    /// simply absent, the answer is "no evidence", and the microphone voice of
    /// the person at the machine is withheld although its own track proves it
    /// was never bleed.
    func testTheEchoEvidenceIsReadUnderTheFolderTheJobRecorded() async throws {
        let recorded = try makeTempDirectory(prefix: "EchoEvidenceRecorded")
        let current = try makeTempDirectory(prefix: "EchoEvidenceCurrent")
        let slug = "standup_abcd1234"
        let recordings = try makeRecordingsDir(in: recorded)
        // Digital silence over the whole segment: the app track carried nothing
        // while the local speaker talked, so that voice cannot be bleed.
        try NamingSessionFixture.writeSilentTracks(
            slug: slug,
            suffixes: [SpeakerNamingStore.mixSuffix, SpeakerNamingStore.appTrackSuffix],
            in: recordings,
        )
        let transcriptPath = recorded.appendingPathComponent("transcript.txt")
        try "] R_SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = NamingSessionFixture.session(outputDir: current)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock
        var job = NamingSessionFixture.pendingJob(
            namingSlug: slug, transcriptPath: transcriptPath,
            echo: EchoDetectionDTO(NamingSessionFixture.echoResult(correlations: [0.9, 0.9, 0.9, 0.9])),
        )
        job.recordSidecarOutputDir(recorded)
        mock.jobs[job.id] = job

        let local = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded
        let remote = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.dualTrackNamingData(
            jobID: job.id, segments: [.init(start: 0, end: 2, speaker: local)],
        )

        session.completeSpeakerNaming(
            jobID: job.id,
            result: .confirmed([remote: "Speaker A", local: "Speaker B"]),
            source: .dialog,
        )

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        let written = try XCTUnwrap(mock.updateSpeakerDBEmbeddings.first)
        XCTAssertEqual(
            written[local], [0, 1, 0],
            "the app track was silent while this voice spoke, so it is admitted",
        )
    }

    /// The newest folder a job recorded is not proof that its files are there:
    /// a write can have failed, or the user can have removed that folder, while
    /// an earlier one still holds every sidecar. The read probes for the file
    /// rather than trusting the order, or a late re-diarization fails and the
    /// echo evidence reads as absent on a job whose files are one folder back.
    func testTheEchoEvidenceIsFoundWhenOnlyAnEarlierFolderHoldsIt() async throws {
        let withAudio = try makeTempDirectory(prefix: "ProbeWithAudio")
        let empty = try makeTempDirectory(prefix: "ProbeEmpty")
        let current = try makeTempDirectory(prefix: "ProbeCurrent")
        let slug = "standup_abcd1234"
        let recordings = try makeRecordingsDir(in: withAudio)
        try NamingSessionFixture.writeSilentTracks(
            slug: slug,
            suffixes: [SpeakerNamingStore.mixSuffix, SpeakerNamingStore.appTrackSuffix],
            in: recordings,
        )
        let transcriptPath = withAudio.appendingPathComponent("transcript.txt")
        try "] R_SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = NamingSessionFixture.session(outputDir: current)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock
        var job = NamingSessionFixture.pendingJob(
            namingSlug: slug, transcriptPath: transcriptPath,
            echo: EchoDetectionDTO(NamingSessionFixture.echoResult(correlations: [0.9, 0.9, 0.9, 0.9])),
        )
        job.recordSidecarOutputDir(withAudio)
        // Recorded last, so the order alone would point here, and it holds
        // nothing.
        job.recordSidecarOutputDir(empty)
        mock.jobs[job.id] = job

        let local = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded
        let remote = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.dualTrackNamingData(
            jobID: job.id, segments: [.init(start: 0, end: 2, speaker: local)],
        )

        session.completeSpeakerNaming(
            jobID: job.id,
            result: .confirmed([remote: "Speaker A", local: "Speaker B"]),
            source: .dialog,
        )

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        let written = try XCTUnwrap(mock.updateSpeakerDBEmbeddings.first)
        XCTAssertEqual(
            written[local], [0, 1, 0],
            "the app track under the earlier folder was silent while this voice spoke",
        )
    }

    /// Saving reports whether it landed, because only a folder that received
    /// the payload may be recorded. A folder the write never reached would
    /// otherwise take the front of the read order and answer with nothing.
    func testSavingNamingDataReportsAFailedWrite() throws {
        let blocked = try makeTempDirectory(prefix: "SaveBlocked")
            .appendingPathComponent("a-file")
        // A regular file where the store wants its folder, so creating
        // `recordings/` underneath it cannot work.
        try Data([0]).write(to: blocked)
        let session = NamingSessionFixture.session(outputDir: blocked)

        let saved = session.saveNamingData(
            NamingSessionFixture.namingData(jobID: UUID()), slug: "meeting", in: blocked,
        )

        XCTAssertFalse(saved)
    }

    func testConfirmOnACleanRecordingStillLearnsBothTracks() async throws {
        let tmp = try makeTempDirectory(prefix: "SpeakerNamingSessionTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] R_SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = NamingSessionFixture.session(outputDir: tmp)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock

        let job = NamingSessionFixture.pendingJob(
            namingSlug: "standup_abcd1234", transcriptPath: transcriptPath,
            echo: EchoDetectionDTO(NamingSessionFixture.echoResult(correlations: [0.2, 0.2, 0.2, 0.2])),
        )
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.dualTrackNamingData(jobID: job.id)

        let local = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded
        let remote = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
        session.completeSpeakerNaming(
            jobID: job.id,
            result: .confirmed([remote: "Speaker A", local: "Speaker B"]),
            source: .dialog,
        )

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        let written = try XCTUnwrap(mock.updateSpeakerDBEmbeddings.first)
        XCTAssertEqual(
            written[local],
            [0, 1, 0],
            "A clean recording must still enroll the person at the machine: a quarantine that "
                + "fires unconditionally would silently stop the app learning the user's own voice",
        )
        XCTAssertEqual(written[remote], [1, 0, 0])
    }

    // MARK: - Confirm

    func testConfirmSynchronouslyTransitionsToGeneratingProtocolThenDone() async throws {
        let tmp = try makeTempDirectory(prefix: "SpeakerNamingSessionTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = NamingSessionFixture.session(outputDir: tmp)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock

        let job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]), source: .dialog)

        // The pending → generatingProtocol hop MUST be synchronous (the RPC
        // idempotency contract): it has already happened when the call returns,
        // before the async re-apply Task runs.
        XCTAssertEqual(mock.stateTransitions.first?.state, .generatingProtocol)

        // The async re-apply then updates the DB, regenerates the protocol, and
        // finishes the job.
        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        XCTAssertEqual(mock.jobs[job.id]?.state, .done)
        XCTAssertEqual(mock.updateSpeakerDBCallCount, 1)
        XCTAssertEqual(mock.generateProtocolCalls.map(\.jobID), [job.id])
        XCTAssertNil(session.speakerNamingDataByJob[job.id], "naming data cleared on confirm")
    }

    // MARK: - Skip

    func testSkipWithoutProtocolFactoryTransitionsToDoneAndClearsData() {
        let session = NamingSessionFixture.session(outputDir: nil) // no protocol factory, no outputDir
        let mock = NamingSessionMockDelegate()
        session.delegate = mock

        let job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: nil)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .skipped, source: .dialog)

        // Skip with no protocol generator is fully synchronous.
        XCTAssertEqual(mock.jobs[job.id]?.state, .done)
        XCTAssertNil(session.speakerNamingDataByJob[job.id], "naming data cleared on skip")
        XCTAssertFalse(mock.generateProtocolCalls.contains { $0.jobID == job.id })
    }

    // MARK: - Missing data / dealloc

    func testCompleteWithNoNamingDataIsNoOp() {
        let session = NamingSessionFixture.session(outputDir: nil)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock

        // No speakerNamingDataByJob entry → guard returns immediately.
        session.completeSpeakerNaming(
            jobID: UUID(), result: .confirmed(["SPEAKER_0": "Alice"]), source: .dialog,
        )
        XCTAssertTrue(mock.stateTransitions.isEmpty)
    }

    func testDeallocatedDelegateMakesOperationsNoOpsNotCrashes() {
        let session = NamingSessionFixture.session(outputDir: nil)
        let jobID = UUID()

        do {
            let mock = NamingSessionMockDelegate()
            session.delegate = mock
            XCTAssertNotNil(session.delegate)
        }
        // `delegate` is weak → the mock is gone once its only strong ref left scope.
        XCTAssertNil(session.delegate, "delegate is weak and was released")

        session.speakerNamingDataByJob[jobID] = NamingSessionFixture.namingData(jobID: jobID)
        // Must not crash even though every delegate callback resolves to nil.
        session.completeSpeakerNaming(jobID: jobID, result: .skipped, source: .dialog)

        // removeNamingData still ran (session-owned, no delegate needed).
        XCTAssertNil(session.speakerNamingDataByJob[jobID])
    }

    // MARK: - In-flight keep-alive

    /// Records delegate activity into a box the test holds separately from the
    /// mock, so assertions survive the mock itself being released mid-flow.
    private final class FlowRecorder {
        var jobs: [UUID: PipelineJob] = [:]
        var transitions: [JobState] = []
        var generateProtocolEntered = 0
        var protocolGate: CheckedContinuation<Void, Never>?
    }

    /// Mock whose `generateProtocol` parks on a continuation, so the test can
    /// deterministically release its own reference while the flow is in-flight.
    private final class GatedMockDelegate: SpeakerNamingSessionDelegate {
        let recorder: FlowRecorder

        init(recorder: FlowRecorder) {
            self.recorder = recorder
        }

        func job(withID id: UUID) -> PipelineJob? {
            recorder.jobs[id]
        }

        func updateJobState(id: UUID, to newState: JobState, error _: String?) {
            recorder.jobs[id]?.state = newState
            recorder.transitions.append(newState)
        }

        func addWarning(id _: UUID, _: String) {}

        func setNamingMetadata(
            jobID _: UUID, slug _: String?, usedDiarizerMode _: DiarizerMode?,
            wroteSidecarsIn _: URL?,
        ) {}

        func updateSpeakerDB(
            matcher _: SpeakerMatcher, mapping _: [String: String],
            embeddings _: [String: [Float]], speakingTimes _: [String: TimeInterval],
        ) {}

        func generateProtocol(jobID _: UUID, transcript _: String, title _: String, protocolsDir _: URL) async {
            recorder.generateProtocolEntered += 1
            await withCheckedContinuation { recorder.protocolGate = $0 }
        }

        func runDualTrackDiarization(
            diarizeProcess _: any DiarizationProvider,
            tracks _: (app: URL, mic: URL, micDelay: TimeInterval, viability: DualTrackViability?),
            speakerCount _: Int?, title _: String, jobID _: UUID,
        ) throws -> DiarizationRun {
            throw DiarizationError.notAvailable
        }

        func renderLabeledTranscript(
            run _: DiarizationRun, cachedSegments _: [TimestampedSegment],
            isDualSource _: Bool, autoNames _: [String: String], note _: String?,
        ) -> String? {
            nil
        }

        func namingStageDidStart(jobID _: UUID) {}
        func namingStageDidEnd() {}
    }

    /// Pins the strong per-flow delegate capture: the delegate is weak *at
    /// rest*, but an in-flight confirm flow must keep the queue alive to
    /// completion (pre-extraction, the queue's own Tasks captured `self`
    /// strongly). Without the capture, a `PipelineController.rebuild()` queue
    /// swap mid-flow would strand the job after the transcript rewrite +
    /// sidecar deletion, and the rebuilt queue would re-process it from
    /// auto-names, dropping the user's corrections.
    func testInFlightConfirmFlowKeepsDelegateAliveAcrossRelease() async throws {
        let tmp = try makeTempDirectory(prefix: "SpeakerNamingSessionTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = NamingSessionFixture.session(outputDir: tmp)
        let recorder = FlowRecorder()
        var mock: GatedMockDelegate? = GatedMockDelegate(recorder: recorder)
        weak let weakMock = mock
        session.delegate = mock

        let job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
        recorder.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]), source: .dialog)

        // Wait until the re-apply flow is provably in-flight (parked inside the
        // delegate's generateProtocol, i.e. mid-"LLM generation").
        await waitFor(recorder.generateProtocolEntered == 1, timeout: .seconds(2))
        XCTAssertEqual(recorder.generateProtocolEntered, 1)

        // Release the test's only strong reference — models the controller
        // swapping queues mid-flow. The flow's strong capture must keep the
        // delegate (the queue) alive.
        mock = nil
        XCTAssertNotNil(weakMock, "in-flight flow holds the delegate strongly")
        XCTAssertNotNil(session.delegate)

        // Let the protocol generation finish: the flow completes against the
        // captured delegate, landing the final `.done`.
        recorder.protocolGate?.resume()
        recorder.protocolGate = nil
        await waitFor(recorder.transitions.contains(.done), timeout: .seconds(2))
        XCTAssertEqual(recorder.transitions, [.generatingProtocol, .done])

        // Once the flow ends, the weak-at-rest delegate zeroes — the per-flow
        // capture is bounded, not a leak.
        await waitFor(weakMock == nil, timeout: .seconds(2))
        XCTAssertNil(weakMock, "delegate released once the flow completes")
        XCTAssertNil(session.delegate)
    }

    // MARK: - No-arg forwarder resolution

    func testHandlerIsInvokedAfterParking() async {
        let session = NamingSessionFixture.session(outputDir: nil)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock

        let job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: nil)
        mock.jobs[job.id] = job

        let expectation = expectation(description: "handler invoked")
        session.speakerNamingHandler = { data in
            XCTAssertEqual(data.jobID, job.id)
            expectation.fulfill()
            return .skipped
        }

        let data = NamingSessionFixture.namingData(jobID: job.id)
        session.speakerNamingDataByJob[job.id] = data
        session.invokeHandler(jobID: job.id, data: data)

        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - Cleanup without an explicit folder follows the job

    /// A caller acting on a live job passes no folder, and that used to mean
    /// "this session's own store", which is the folder the queue writes to
    /// *now*. Once the user picks a new output folder, a job's sidecars sit
    /// under the folder it recorded, so the cleanup looked in the new one, found
    /// nothing, and left hundreds of megabytes of 16 kHz tracks behind for a
    /// dual-source hour. Nothing else sweeps them: the job is gone from the
    /// snapshot that would have named them.
    ///
    /// The restore path always passed the folder explicitly and was therefore
    /// correct; these are the five call sites that did not, among them the late
    /// confirmation, the auto-name accept and cancelling a job.
    func testCleanupWithoutAFolderUsesTheOneTheJobRecorded() throws {
        let recorded = try makeTempDirectory(prefix: "SidecarRecorded")
        let current = try makeTempDirectory(prefix: "SidecarCurrent")
        let recordings = recorded.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let sidecars = try SidecarFixture.write(slug: "meeting", in: recordings)

        // The session writes to `current`; the job recorded `recorded`. The
        // session's own store gets `current` too, so a cleanup that ignores the
        // job has a real folder to miss rather than no folder at all.
        let session = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: current),
            speakerMatcherFactory: PipelineQueue.throwawayMatcherFactory(),
            outputDir: current,
        )
        let delegate = NamingSessionMockDelegate()
        session.delegate = delegate
        var job = PipelineJob(
            meetingTitle: "Meeting", appName: "Teams",
            mixPath: recordings.appendingPathComponent("meeting_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.namingSlug = "meeting"
        job.recordSidecarOutputDir(recorded)
        delegate.jobs[job.id] = job

        session.removeNamingData(jobID: job.id, slug: "meeting")

        assertSidecars(sidecars, exist: false)
    }

    /// A job that recorded no folder, so there is nothing to follow: the
    /// session's own folder stays the answer, which is what every caller got
    /// before the field existed.
    ///
    /// Green before and after the change, deliberately: it guards the fallback
    /// rather than proving the fix. An implementation that resolved nil to a
    /// store with no folder would do nothing at all and still look correct.
    func testCleanupFallsBackToTheSessionFolderWhenTheJobRecordedNone() throws {
        let current = try makeTempDirectory(prefix: "SidecarFallback")
        let recordings = current.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let sidecars = try SidecarFixture.write(slug: "meeting", in: recordings)

        let session = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: current),
            speakerMatcherFactory: PipelineQueue.throwawayMatcherFactory(),
            outputDir: current,
        )
        let delegate = NamingSessionMockDelegate()
        session.delegate = delegate
        var job = PipelineJob(
            meetingTitle: "Meeting", appName: "Teams",
            mixPath: recordings.appendingPathComponent("meeting_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.namingSlug = "meeting"
        delegate.jobs[job.id] = job

        session.removeNamingData(jobID: job.id, slug: "meeting")

        assertSidecars(sidecars, exist: false)
    }
}
