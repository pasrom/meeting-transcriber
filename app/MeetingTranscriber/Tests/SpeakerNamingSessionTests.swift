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
    // MARK: - Mock delegate

    /// Records every delegate callback and models the minimal queue state the
    /// session reads back (a per-id job whose `state` `updateJobState` mutates).
    private final class MockDelegate: SpeakerNamingSessionDelegate {
        var jobs: [UUID: PipelineJob] = [:]
        private(set) var stateTransitions: [(id: UUID, state: JobState)] = []
        private(set) var warnings: [(id: UUID, message: String)] = []
        private(set) var generateProtocolCalls: [(jobID: UUID, title: String)] = []
        private(set) var updateSpeakerDBCallCount = 0
        private(set) var metadataUpdates: [(jobID: UUID, slug: String?, mode: DiarizerMode?)] = []
        private(set) var stageStartCount = 0
        private(set) var stageEndCount = 0

        func job(withID id: UUID) -> PipelineJob? {
            jobs[id]
        }

        func updateJobState(id: UUID, to newState: JobState, error _: String?) {
            jobs[id]?.state = newState
            stateTransitions.append((id, newState))
        }

        func addWarning(id: UUID, _ message: String) {
            warnings.append((id, message))
        }

        func setNamingMetadata(jobID: UUID, slug: String?, usedDiarizerMode: DiarizerMode?) {
            metadataUpdates.append((jobID, slug, usedDiarizerMode))
        }

        func updateSpeakerDB(
            matcher _: SpeakerMatcher, mapping _: [String: String],
            embeddings _: [String: [Float]], speakingTimes _: [String: TimeInterval],
        ) {
            updateSpeakerDBCallCount += 1
        }

        func generateProtocol(jobID: UUID, transcript _: String, title: String, protocolsDir _: URL) {
            generateProtocolCalls.append((jobID, title))
        }

        func runDualTrackDiarization(
            diarizeProcess _: any DiarizationProvider,
            tracks _: (app: URL, mic: URL, micDelay: TimeInterval),
            speakerCount _: Int?, title _: String, jobID _: UUID,
        ) throws -> DiarizationRun {
            throw DiarizationError.notAvailable
        }

        func renderLabeledTranscript(
            run _: DiarizationRun, cachedSegments _: [TimestampedSegment],
            isDualSource _: Bool, autoNames _: [String: String],
        ) -> String? {
            nil
        }

        func namingStageDidStart(jobID _: UUID) {
            stageStartCount += 1
        }

        func namingStageDidEnd() {
            stageEndCount += 1
        }
    }

    // MARK: - Helpers

    private func makeSession(outputDir: URL?) -> SpeakerNamingSession {
        SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: nil),
            speakerMatcherFactory: PipelineQueue.throwawayMatcherFactory(),
            outputDir: outputDir,
        )
    }

    private func makeNamingData(jobID: UUID) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: jobID,
            meetingTitle: "Standup",
            mapping: ["SPEAKER_0": "SPEAKER_0"],
            speakingTimes: ["SPEAKER_0": 12],
            embeddings: ["SPEAKER_0": [0.1, 0.2, 0.3]],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: false,
        )
    }

    private func pendingJob(namingSlug: String?, transcriptPath: URL?) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Standup", appName: "Test",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.namingSlug = namingSlug
        job.transcriptPath = transcriptPath
        return job
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Confirm

    func testConfirmSynchronouslyTransitionsToGeneratingProtocolThenDone() async throws {
        let tmp = try makeTempDirectory(prefix: "SpeakerNamingSessionTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = makeSession(outputDir: tmp)
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))

        // The pending → generatingProtocol hop MUST be synchronous (the RPC
        // idempotency contract): it has already happened when the call returns,
        // before the async re-apply Task runs.
        XCTAssertEqual(mock.stateTransitions.first?.state, .generatingProtocol)

        // The async re-apply then updates the DB, regenerates the protocol, and
        // finishes the job.
        await waitUntil { mock.jobs[job.id]?.state == .done }
        XCTAssertEqual(mock.jobs[job.id]?.state, .done)
        XCTAssertEqual(mock.updateSpeakerDBCallCount, 1)
        XCTAssertEqual(mock.generateProtocolCalls.map(\.jobID), [job.id])
        XCTAssertNil(session.speakerNamingDataByJob[job.id], "naming data cleared on confirm")
    }

    // MARK: - Skip

    func testSkipWithoutProtocolFactoryTransitionsToDoneAndClearsData() {
        let session = makeSession(outputDir: nil) // no protocol factory, no outputDir
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(namingSlug: "standup_abcd1234", transcriptPath: nil)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .skipped)

        // Skip with no protocol generator is fully synchronous.
        XCTAssertEqual(mock.jobs[job.id]?.state, .done)
        XCTAssertNil(session.speakerNamingDataByJob[job.id], "naming data cleared on skip")
        XCTAssertFalse(mock.generateProtocolCalls.contains { $0.jobID == job.id })
    }

    // MARK: - Missing data / dealloc

    func testCompleteWithNoNamingDataIsNoOp() {
        let session = makeSession(outputDir: nil)
        let mock = MockDelegate()
        session.delegate = mock

        // No speakerNamingDataByJob entry → guard returns immediately.
        session.completeSpeakerNaming(jobID: UUID(), result: .confirmed(["SPEAKER_0": "Alice"]))
        XCTAssertTrue(mock.stateTransitions.isEmpty)
    }

    func testDeallocatedDelegateMakesOperationsNoOpsNotCrashes() {
        let session = makeSession(outputDir: nil)
        let jobID = UUID()

        do {
            let mock = MockDelegate()
            session.delegate = mock
            XCTAssertNotNil(session.delegate)
        }
        // `delegate` is weak → the mock is gone once its only strong ref left scope.
        XCTAssertNil(session.delegate, "delegate is weak and was released")

        session.speakerNamingDataByJob[jobID] = makeNamingData(jobID: jobID)
        // Must not crash even though every delegate callback resolves to nil.
        session.completeSpeakerNaming(jobID: jobID, result: .skipped)

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

        func setNamingMetadata(jobID _: UUID, slug _: String?, usedDiarizerMode _: DiarizerMode?) {}

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
            tracks _: (app: URL, mic: URL, micDelay: TimeInterval),
            speakerCount _: Int?, title _: String, jobID _: UUID,
        ) throws -> DiarizationRun {
            throw DiarizationError.notAvailable
        }

        func renderLabeledTranscript(
            run _: DiarizationRun, cachedSegments _: [TimestampedSegment],
            isDualSource _: Bool, autoNames _: [String: String],
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

        let session = makeSession(outputDir: tmp)
        let recorder = FlowRecorder()
        var mock: GatedMockDelegate? = GatedMockDelegate(recorder: recorder)
        weak let weakMock = mock
        session.delegate = mock

        let job = pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
        recorder.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))

        // Wait until the re-apply flow is provably in-flight (parked inside the
        // delegate's generateProtocol, i.e. mid-"LLM generation").
        await waitUntil { recorder.generateProtocolEntered == 1 }
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
        await waitUntil { recorder.transitions.contains(.done) }
        XCTAssertEqual(recorder.transitions, [.generatingProtocol, .done])

        // Once the flow ends, the weak-at-rest delegate zeroes — the per-flow
        // capture is bounded, not a leak.
        await waitUntil { weakMock == nil }
        XCTAssertNil(weakMock, "delegate released once the flow completes")
        XCTAssertNil(session.delegate)
    }

    // MARK: - No-arg forwarder resolution

    func testHandlerIsInvokedAfterParking() async {
        let session = makeSession(outputDir: nil)
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(namingSlug: "standup_abcd1234", transcriptPath: nil)
        mock.jobs[job.id] = job

        let expectation = expectation(description: "handler invoked")
        session.speakerNamingHandler = { data in
            XCTAssertEqual(data.jobID, job.id)
            expectation.fulfill()
            return .skipped
        }

        let data = makeNamingData(jobID: job.id)
        session.speakerNamingDataByJob[job.id] = data
        session.invokeHandler(jobID: job.id, data: data)

        await fulfillment(of: [expectation], timeout: 2)
    }
}
