@testable import MeetingTranscriber
import XCTest

@MainActor
final class WorkflowIntegrationTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    // swiftlint:disable:next unneeded_throws_rethrows
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Harness

    private struct Harness {
        let queue: PipelineQueue
        let engine: MockEngine
        let diarization: MockDiarization
        let protocolGen: MockProtocolGen
        let audioPath: URL
    }

    /// Reference-type collector for state transitions captured via onJobStateChange.
    private final class TransitionCollector {
        var transitions: [(JobState, JobState)] = []
    }

    private func makeHarness(
        diarizeEnabled: Bool = false,
    ) throws -> (Harness, TransitionCollector) {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello world"),
            TimestampedSegment(start: 5, end: 10, text: "This is a test"),
        ]

        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_00"),
                .init(start: 5, end: 10, speaker: "SPEAKER_01"),
            ],
            speakingTimes: ["SPEAKER_00": 5.0, "SPEAKER_01": 5.0],
            autoNames: [:],
            embeddings: ["SPEAKER_00": [1, 0, 0], "SPEAKER_01": [0, 1, 0]],
        )

        let protocolGen = MockProtocolGen()
        let collector = TransitionCollector()

        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: diarizeEnabled,
            micLabel: "Me",
        )

        queue.onJobStateChange = { [collector] _, old, new in
            collector.transitions.append((old, new))
        }

        let audioPath = try createTestAudioFile(in: tmpDir)

        let harness = Harness(
            queue: queue, engine: engine, diarization: diarization,
            protocolGen: protocolGen, audioPath: audioPath,
        )
        return (harness, collector)
    }

    // swiftlint:disable:next function_default_parameter_at_end
    private func makeJob(title: String = "Test Meeting", audioPath: URL) -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: audioPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }

    // swiftlint:disable:next function_default_parameter_at_end
    private func makeDualSourceJob(title: String = "Dual Meeting", audioPath: URL) throws -> PipelineJob {
        let appPath = tmpDir.appendingPathComponent("app_\(UUID().uuidString).wav")
        let micPath = tmpDir.appendingPathComponent("mic_\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: audioPath, to: appPath)
        try FileManager.default.copyItem(at: audioPath, to: micPath)
        return PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: audioPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: 0,
        )
    }

    // MARK: - Happy Path: Single-Source, No Diarization

    func testWorkflowSingleSourceNoDiarization() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: false)
        let job = makeJob(audioPath: h.audioPath)

        h.queue.enqueue(job)
        await h.queue.processNext()

        // State transitions: waiting → transcribing → generatingProtocol → done
        XCTAssertEqual(
            collector.transitions.map(\.1),
            [.transcribing, .generatingProtocol, .done],
        )

        // Engine was called once, diarization not at all
        XCTAssertEqual(h.engine.transcribeCallCount, 1)
        XCTAssertEqual(h.diarization.runCount, 0)

        // Protocol generator received transcript
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertEqual(h.protocolGen.capturedTitle, "Test Meeting")
        XCTAssertTrue(h.protocolGen.capturedTranscript?.contains("Hello world") ?? false)

        // Job is done with protocol file on disk
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertNotNil(h.queue.jobs.first?.protocolPath)

        if let path = h.queue.jobs.first?.protocolPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        }
    }

    // MARK: - Happy Path: Single-Source, Diarization + Speaker Naming

    func testWorkflowWithDiarizationAndNaming() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: true)

        h.queue.speakerNamingHandler = { data in
            // Verify naming data is populated
            XCTAssertFalse(data.mapping.isEmpty)
            XCTAssertFalse(data.speakingTimes.isEmpty)
            return .confirmed(["SPEAKER_00": "Alice", "SPEAKER_01": "Speaker C"])
        }

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // State transitions: waiting → transcribing → diarizing → generatingProtocol → done
        XCTAssertEqual(
            collector.transitions.map(\.1),
            [.transcribing, .diarizing, .generatingProtocol, .done],
        )

        // Diarization called once, protocol generated
        XCTAssertEqual(h.diarization.runCount, 1)
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
    }

    // MARK: - Happy Path: Dual-Source

    func testWorkflowDualSource() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: false)
        let job = try makeDualSourceJob(audioPath: h.audioPath)

        h.queue.enqueue(job)
        await h.queue.processNext()

        // Engine called twice (app + mic tracks)
        XCTAssertEqual(h.engine.transcribeCallCount, 2)

        // Protocol generated with merged transcript containing "Remote" label
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertTrue(
            h.protocolGen.capturedTranscript?.contains("Remote") ?? false,
            "Dual-source transcript should contain 'Remote' speaker label",
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
    }

    // MARK: - Error Scenarios

    func testWorkflowEmptyTranscriptEndsInError() async throws {
        let (h, collector) = try makeHarness()
        h.engine.segmentsToReturn = [] // no speech

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // State: waiting → transcribing → error
        XCTAssertEqual(collector.transitions.map(\.1), [.transcribing, .error])
        XCTAssertEqual(h.queue.jobs.first?.state, .error)
        XCTAssertEqual(h.queue.jobs.first?.error, "Empty transcript")

        // Protocol was NOT generated
        XCTAssertFalse(h.protocolGen.generateCalled)
    }

    func testWorkflowEngineThrowsEndsInError() async throws {
        let (h, _) = try makeHarness()
        h.engine.shouldThrow = true

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Job ends in error
        XCTAssertEqual(h.queue.jobs.first?.state, .error)
        XCTAssertFalse(h.protocolGen.generateCalled)
    }

    func testWorkflowProtocolGenerationFailsSavesTranscriptWithWarning() async throws {
        let (h, _) = try makeHarness()
        h.protocolGen.shouldThrow = true

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Job completes with warning (graceful fallback), transcript saved
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertNotNil(h.queue.jobs.first?.transcriptPath)
        XCTAssertNil(h.queue.jobs.first?.protocolPath)
        XCTAssertFalse(h.queue.jobs.first?.warnings.isEmpty ?? true)
    }

    // MARK: - Diarization Scenarios

    func testWorkflowDiarizationUnavailableSkips() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: true)
        h.diarization.isAvailable = false

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Should skip diarization — no .diarizing state, but protocol still generated
        let states = collector.transitions.map(\.1)
        XCTAssertFalse(states.contains(.diarizing))
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
    }

    func testWorkflowDiarizationNoEmbeddingsFallsBack() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)
        h.diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_00")],
            speakingTimes: ["SPEAKER_00": 5],
            autoNames: [:],
            embeddings: nil, // no embeddings → naming loop breaks early
        )

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Should complete despite no embeddings
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(h.protocolGen.generateCalled)
    }

    // MARK: - Speaker Naming Scenarios

    func testWorkflowSpeakerNamingSkipped() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)
        h.queue.speakerNamingHandler = { _ in .skipped }

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Still completes even when naming is skipped
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(h.protocolGen.generateCalled)
    }

    func testWorkflowSpeakerNamingRerun() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)

        var callCount = 0
        h.queue.speakerNamingHandler = { _ in
            callCount += 1
            return callCount == 1 ? .rerun(3) : .confirmed(["SPEAKER_00": "Alice"])
        }

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Handler called twice (first rerun, then confirm), diarization ran twice
        XCTAssertEqual(callCount, 2)
        XCTAssertGreaterThanOrEqual(h.diarization.runCount, 2)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
    }

    // MARK: - Multi-Job

    func testMultipleJobsProcessedSequentially() async throws {
        let (h, _) = try makeHarness()

        // Enqueue and process first job
        let job1 = makeJob(title: "Meeting 1", audioPath: h.audioPath)
        h.queue.enqueue(job1)
        await h.queue.processNext()
        XCTAssertEqual(h.queue.jobs.first { $0.id == job1.id }?.state, .done)

        // Enqueue and process second job
        let audio2 = try createTestAudioFile(in: tmpDir)
        let job2 = makeJob(title: "Meeting 2", audioPath: audio2)
        h.queue.enqueue(job2)
        await h.queue.processNext()
        XCTAssertEqual(h.queue.jobs.first { $0.id == job2.id }?.state, .done)

        // Engine called twice total (once per job)
        XCTAssertEqual(h.engine.transcribeCallCount, 2)
    }

    func testErrorJobDoesNotBlockNextJob() async throws {
        let (h, _) = try makeHarness()

        // First job will fail (empty transcript)
        let audio1 = try createTestAudioFile(in: tmpDir)
        let job1 = makeJob(title: "Silent", audioPath: audio1)
        h.engine.segmentsToReturn = []
        h.queue.enqueue(job1)
        await h.queue.processNext()
        XCTAssertEqual(h.queue.jobs.first?.state, .error)

        // Second job should succeed
        h.engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Now it works"),
        ]
        let audio2 = try createTestAudioFile(in: tmpDir)
        let job2 = makeJob(title: "Working", audioPath: audio2)
        h.queue.enqueue(job2)
        await h.queue.processNext()
        XCTAssertEqual(h.queue.jobs.first { $0.id == job2.id }?.state, .done)
    }

    // MARK: - Single-Source Fallback (App-Only / Mic-Only)

    func testWorkflowAppOnlyNoMic() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: false)
        let appPath = tmpDir.appendingPathComponent("app_\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: h.audioPath, to: appPath)

        let job = PipelineJob(
            meetingTitle: "App Only Meeting",
            appName: "Microsoft Teams",
            mixPath: h.audioPath,
            appPath: appPath,
            micPath: nil,
            micDelay: 0,
        )

        h.queue.enqueue(job)
        await h.queue.processNext()

        // Should complete as single-source (app track only)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(collector.transitions.map(\.1).contains(.done))

        // Engine called once (single-source fallback)
        XCTAssertEqual(h.engine.transcribeCallCount, 1)

        // Protocol generated
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertNotNil(h.queue.jobs.first?.protocolPath)
    }

    func testWorkflowMicOnlyNoApp() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: false)
        let micPath = tmpDir.appendingPathComponent("mic_\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: h.audioPath, to: micPath)

        let job = PipelineJob(
            meetingTitle: "Mic Only Meeting",
            appName: "Microsoft Teams",
            mixPath: h.audioPath,
            appPath: nil,
            micPath: micPath,
            micDelay: 0,
        )

        h.queue.enqueue(job)
        await h.queue.processNext()

        // Should complete as single-source (mic track only)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(collector.transitions.map(\.1).contains(.done))

        // Engine called once (single-source fallback)
        XCTAssertEqual(h.engine.transcribeCallCount, 1)

        // Protocol generated
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertNotNil(h.queue.jobs.first?.protocolPath)
    }

    // MARK: - None LLM Provider (Transcript Only)

    func testWorkflowNoneProviderSavesTranscriptOnly() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello world"),
        ]
        let collector = TransitionCollector()

        // Factory returns nil → no protocol generation
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: tmpDir,
            logDir: tmpDir,
        )
        queue.onJobStateChange = { [collector] _, old, new in
            collector.transitions.append((old, new))
        }

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = makeJob(title: "Transcript Only", audioPath: audioPath)
        queue.enqueue(job)
        await queue.processNext()

        // Job completes without .generatingProtocol state
        let states = collector.transitions.map(\.1)
        XCTAssertFalse(states.contains(.generatingProtocol))
        XCTAssertEqual(queue.jobs.first?.state, .done)

        // Transcript saved, no protocol
        XCTAssertNotNil(queue.jobs.first?.transcriptPath)
        XCTAssertNil(queue.jobs.first?.protocolPath)

        // No warnings (this is intentional, not a failure)
        XCTAssertTrue(queue.jobs.first?.warnings.isEmpty ?? false)
    }
}
