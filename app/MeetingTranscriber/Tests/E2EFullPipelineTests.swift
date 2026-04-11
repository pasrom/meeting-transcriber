@testable import MeetingTranscriber
import XCTest

/// End-to-end pipeline test with **zero mocks**.
///
/// Launches the meeting-simulator tool (which opens a window, creates a power assertion,
/// and plays audio). WatchLoop detects the meeting via PowerAssertionDetector,
/// DualSourceRecorder taps the simulator's audio via CATapDescription, Parakeet
/// transcribes the recording, FluidDiarizer identifies speakers, and the test verifies
/// that the transcript output file exists and contains recognized speech.
///
/// Skipped in CI — requires audio hardware, mic permission, and model downloads.
/// Run locally: `swift test --filter E2EFullPipeline`
@MainActor
class E2EFullPipelineTests: XCTestCase {
    private static var simulatorBinary: URL?
    private var tmpDir: URL?

    // MARK: - Setup

    private static var shouldSkip: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
            && ProcessInfo.processInfo.environment["E2E_ENABLED"] == nil
    }

    override class func setUp() {
        super.setUp()
        guard !shouldSkip else { return }
        do {
            simulatorBinary = try SimulatorHelper.buildSimulator()
        } catch {
            XCTFail("Failed to build meeting-simulator: \(error)")
        }
    }

    override func setUp() async throws {
        try XCTSkipIf(
            Self.shouldSkip,
            "E2E test requires audio hardware — set E2E_ENABLED=1 on self-hosted runners",
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e_pipeline_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tmpDir = dir
    }

    override func tearDown() async throws { // swiftlint:disable:this unneeded_throws_rethrows
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Full Pipeline

    func testFullPipelineDetectRecordTranscribeDiarize() async throws {
        let outputDir = try XCTUnwrap(tmpDir, "tmpDir not set")

        // 1. Real Parakeet engine — downloads model on first run (~50 MB)
        let engine = ParakeetEngine()
        await engine.loadModel()

        // 2. Real pipeline: Parakeet + FluidDiarizer + no LLM (transcript only)
        let diarizer = FluidDiarizer()
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { diarizer },
            protocolGeneratorFactory: { nil },
            outputDir: outputDir,
            logDir: outputDir,
            diarizeEnabled: true,
            numSpeakers: 2,
            micLabel: "Me",
        )
        queue.speakerNamingHandler = { _ in .skipped }

        // 3. Track pipeline completion (guard against double-fulfill)
        let pipelineDone = expectation(description: "Pipeline completes")
        var fulfilled = false
        queue.onJobStateChange = { _, _, newState in
            if newState == .done || newState == .error, !fulfilled {
                fulfilled = true
                pipelineDone.fulfill()
            }
        }

        // 4. Real WatchLoop: PowerAssertionDetector + DualSourceRecorder
        let detector = PowerAssertionDetector()
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { DualSourceRecorder() },
            pipelineQueue: queue,
            pollInterval: 1.0,
            endGracePeriod: 5.0,
        )
        loop.start()
        addTeardownBlock { loop.stop() }

        // 5. Launch meeting simulator — plays two_speakers_de.wav (~53s)
        let binary = try XCTUnwrap(Self.simulatorBinary, "meeting-simulator binary not built")
        let simulator = try SimulatorHelper.launchSimulator(
            binary: binary,
            audioPath: SimulatorHelper.fixtureAudio,
        )
        addTeardownBlock {
            if simulator.isRunning { simulator.terminate() }
        }

        // 6. Wait for pipeline completion
        // ~53s audio + 5s grace + model inference + overhead
        await fulfillment(of: [pipelineDone], timeout: 120)

        // 7. Assertions
        let job = try XCTUnwrap(queue.jobs.first, "Expected at least one pipeline job")
        XCTAssertEqual(job.state, .done, "Job should complete. Error: \(job.error ?? "none")")
        XCTAssertNil(job.error)

        // Transcript file exists and has content
        let transcriptPath = try XCTUnwrap(job.transcriptPath, "Transcript path should be set")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: transcriptPath.path),
            "Transcript file should exist",
        )
        let transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
        XCTAssertFalse(transcript.isEmpty, "Transcript should not be empty")

        print("=== E2E Full Pipeline Test Passed ===")
        print("Transcript length: \(transcript.count) chars")
        print("Transcript preview: \(String(transcript.prefix(300)))")
    }
}
