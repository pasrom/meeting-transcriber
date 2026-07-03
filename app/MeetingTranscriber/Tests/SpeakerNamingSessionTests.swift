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
