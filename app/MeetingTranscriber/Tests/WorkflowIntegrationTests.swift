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
            return .confirmed(["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"])
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
}
