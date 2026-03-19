import AVFoundation
@testable import MeetingTranscriber
import XCTest

// MARK: - Tests

@MainActor
final class WatchLoopE2ETests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchloop_e2e_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Ensure recordingsDir exists (handleMeeting writes intermediate 16kHz files there)
        try FileManager.default.createDirectory(
            at: DualSourceRecorder.recordingsDir,
            withIntermediateDirectories: true,
        )
    }

    override func tearDown() async throws {
        if let tmpDir, FileManager.default.fileExists(atPath: tmpDir.path) {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("two_speakers_de.wav")
    }

    /// Upsample the fixture to 48kHz to simulate DualSourceRecorder output, save to tmpDir.
    private func prepare48kHzFixture(name: String = "mix.wav") throws -> URL {
        let fixture = fixtureURL()
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: fixture)

        // Determine source sample rate
        let file = try AVAudioFile(forReading: fixture)
        let sourceRate = Int(file.processingFormat.sampleRate)

        // Resample to 48kHz
        let upsampled = sourceRate == 48000
            ? samples
            : AudioMixer.resample(samples, from: sourceRate, to: 48000)

        let outPath = tmpDir.appendingPathComponent(name)
        try AudioMixer.saveWAV(samples: upsampled, sampleRate: 48000, url: outPath)
        return outPath
    }

    /// Create a mock meeting for testing.
    private func makeMeeting(pid: pid_t = 9999) -> DetectedMeeting {
        DetectedMeeting(
            pattern: .teams,
            windowTitle: "Test Meeting | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: pid,
        )
    }

    /// Create a PipelineQueue with mocks for E2E testing.
    private func makeQueue(
        transcriptionEngine: FluidTranscriptionEngine? = nil,
        diarization: MockDiarization = MockDiarization(),
        protocolGen: MockProtocolGen = MockProtocolGen(),
        diarizeEnabled: Bool = false,
        micLabel: String = "Roman",
    ) -> PipelineQueue {
        PipelineQueue(
            transcriptionEngine: transcriptionEngine ?? FluidTranscriptionEngine(),
            diarizationFactory: { diarization },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: diarizeEnabled,
            micLabel: micLabel,
        )
    }

    /// Create a WatchLoop with injected mocks and immediate meeting-end detection.
    private func makeLoop(
        recorder: MockRecorder,
        pipelineQueue: PipelineQueue,
    ) -> WatchLoop {
        let detector = PowerAssertionDetector()
        // Meeting ends immediately (no assertions)
        detector.assertionProvider = { [:] }

        return WatchLoop(
            detector: detector,
            recorderFactory: { recorder },
            pipelineQueue: pipelineQueue,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 10,
            noMic: false,
        )
    }

    // MARK: - 1. Full Pipeline: detect → record → enqueue → transcribe → protocol

    func testFullPipelineDetectRecordTranscribeProtocol() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires Parakeet model download",
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let mixPath = try prepare48kHzFixture()
        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let mockProtocol = MockProtocolGen()
        let engine = FluidTranscriptionEngine()
        engine.modelVariant = "parakeet-tdt-0.6b-v2-coreml"

        let queue = makeQueue(
            transcriptionEngine: engine,
            protocolGen: mockProtocol,
            diarizeEnabled: false,
        )
        let loop = makeLoop(recorder: recorder, pipelineQueue: queue)

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        // Verify recording happened
        XCTAssertTrue(recorder.startCalled)
        XCTAssertTrue(recorder.stopCalled)

        // Verify job was enqueued
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].state, .waiting)

        // Process the job through the pipeline
        await queue.processNext()

        // Verify protocol was generated
        XCTAssertTrue(mockProtocol.generateCalled, "Protocol generator should have been called")
        XCTAssertEqual(queue.jobs[0].state, .done, "Job should be done after processing")
        XCTAssertNotNil(queue.jobs[0].protocolPath, "Job should have a protocol path")

        // Verify the transcript was non-empty
        XCTAssertNotNil(mockProtocol.capturedTranscript, "Transcript should be captured")
        XCTAssertFalse(
            mockProtocol.capturedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
            "Transcript should not be empty",
        )
    }

    // MARK: - 2. Dual Source Transcription Path

    func testDualSourceTranscriptionPath() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires Parakeet model download",
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        // Prepare separate app and mic audio (both 48kHz)
        let appPath = try prepare48kHzFixture(name: "app.wav")
        let micPath = try prepare48kHzFixture(name: "mic.wav")
        let mixPath = try prepare48kHzFixture(name: "mix.wav")

        let recorder = MockRecorder()
        recorder.mixPath = mixPath
        recorder.appPath = appPath
        recorder.micPath = micPath

        let mockProtocol = MockProtocolGen()
        let engine = FluidTranscriptionEngine()
        engine.modelVariant = "parakeet-tdt-0.6b-v2-coreml"

        let queue = makeQueue(
            transcriptionEngine: engine,
            protocolGen: mockProtocol,
            diarizeEnabled: false,
            micLabel: "Roman",
        )
        let loop = makeLoop(recorder: recorder, pipelineQueue: queue)

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        // Verify dual-source paths were stored in the job
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertNotNil(queue.jobs[0].appPath, "Job should have app audio path")
        XCTAssertNotNil(queue.jobs[0].micPath, "Job should have mic audio path")

        // Process the job
        await queue.processNext()

        // Verify protocol was generated with speaker-labeled transcript
        XCTAssertTrue(mockProtocol.generateCalled, "Protocol generator should have been called")
        XCTAssertEqual(queue.jobs[0].state, .done, "Job should be done after dual-source processing")

        // Verify transcript contains speaker labels (Roman / Remote)
        if let transcript = mockProtocol.capturedTranscript {
            let hasLabels = transcript.contains("Roman") || transcript.contains("Remote")
            XCTAssertTrue(hasLabels, "Dual-source transcript should contain speaker labels, got: \(transcript.prefix(200))")
        }
    }

    // MARK: - 3. Empty Transcript Transitions to Error

    func testEmptyTranscriptTransitionsToError() async throws {
        // Create a silent (all zeros) 48kHz WAV — Transcription engine should produce empty transcript
        let silentSamples = [Float](repeating: 0.0, count: 48000)
        let mixPath = tmpDir.appendingPathComponent("silent.wav")
        try AudioMixer.saveWAV(samples: silentSamples, sampleRate: 48000, url: mixPath)

        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let engine = FluidTranscriptionEngine()
        engine.modelVariant = "parakeet-tdt-0.6b-v2-coreml"

        let mockProtocol = MockProtocolGen()
        let queue = makeQueue(
            transcriptionEngine: engine,
            protocolGen: mockProtocol,
            diarizeEnabled: false,
        )
        let loop = makeLoop(recorder: recorder, pipelineQueue: queue)

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].state, .waiting)

        // Process the job — should fail with empty transcript
        await queue.processNext()

        XCTAssertEqual(queue.jobs[0].state, .error, "Job should be in error state for empty transcript")
        XCTAssertFalse(mockProtocol.generateCalled, "Protocol should NOT be generated for empty transcript")
    }

    // MARK: - 4. Diarization Skipped When Not Available

    func testDiarizationSkippedWhenNotAvailable() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires Parakeet model download",
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let mixPath = try prepare48kHzFixture()
        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let mockDiarize = MockDiarization()
        mockDiarize.isAvailable = false // Simulate diarization not available

        let mockProtocol = MockProtocolGen()
        let engine = FluidTranscriptionEngine()
        engine.modelVariant = "parakeet-tdt-0.6b-v2-coreml"

        let queue = makeQueue(
            transcriptionEngine: engine,
            diarization: mockDiarize,
            protocolGen: mockProtocol,
            diarizeEnabled: true, // Enabled but not available
        )
        let loop = makeLoop(recorder: recorder, pipelineQueue: queue)

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)
        await queue.processNext()

        // Protocol should still be generated (diarization skipped gracefully)
        XCTAssertTrue(mockProtocol.generateCalled, "Protocol should be generated even when diarization is unavailable")
        XCTAssertEqual(queue.jobs[0].state, .done, "Job should complete despite unavailable diarization")
        XCTAssertFalse(mockDiarize.runCalled, "Diarization should NOT have been run")

        // Verify the transcript was passed as non-diarized
        XCTAssertFalse(mockProtocol.capturedDiarized ?? true, "Should be marked as non-diarized")
    }

    // MARK: - 5. Cooldown Prevents Re-detection After Handling

    func testCooldownPreventsRedetectionAfterHandling() {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.windowListProvider = { [] }

        let teamsAssertions: [Int32: [[String: Any]]] = [
            1234: [[
                "Process Name": "MSTeams",
                "AssertName": "Microsoft Teams Call in progress",
            ]],
        ]
        detector.assertionProvider = { teamsAssertions }

        // First detection succeeds
        let firstDetection = detector.checkOnce()
        XCTAssertNotNil(firstDetection, "Should detect meeting on first check")

        // Reset with cooldown
        detector.reset(appName: "Microsoft Teams")

        // Second detection should fail due to cooldown
        let secondDetection = detector.checkOnce()
        XCTAssertNil(secondDetection, "Should NOT detect meeting during cooldown")
    }

    // MARK: - 6. Resample Path Produces 16kHz for FluidTranscriptionEngine
    
    func testResamplePathProduces16kHzForTranscription() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires Parakeet model download",
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        // Create 48kHz version
        let path48k = try prepare48kHzFixture(name: "resample_test.wav")

        // Resample to 16kHz (same path as PipelineQueue)
        let samples48k = try AudioMixer.loadAudioFileAsFloat32(url: path48k)
        let resampled = AudioMixer.resample(samples48k, from: 48000, to: 16000)

        let path16k = tmpDir.appendingPathComponent("resample_test_16k.wav")
        try AudioMixer.saveWAV(samples: resampled, sampleRate: 16000, url: path16k)

        // Verify 16kHz file header
        let audioFile = try AVAudioFile(forReading: path16k)
        XCTAssertEqual(
            Int(audioFile.processingFormat.sampleRate), 16000,
            "Resampled file should be 16kHz",
        )

        // Verify transcriber can transcribe the 16kHz file
        let engine = FluidTranscriptionEngine()
        engine.modelVariant = "parakeet-tdt-0.6b-v2-coreml"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        let transcript = try await engine.transcribe(audioPath: path16k)
        XCTAssertFalse(transcript.isEmpty, "FluidTranscriptionEngine should produce non-empty transcript from 16kHz audio")

        // Verify no special tokens
        XCTAssertFalse(transcript.contains("<|"), "Transcript should not contain '<|'")
        XCTAssertFalse(transcript.contains("|>"), "Transcript should not contain '|>'")
    }

    // MARK: - 7. Full Pipeline With Real Diarization (slow)

    func testFullPipelineWithRealDiarization() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires Parakeet model + FluidAudio diarization",
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let realDiarize = FluidDiarizer()
        try XCTSkipUnless(realDiarize.isAvailable, "FluidAudio diarization not available")

        let mixPath = try prepare48kHzFixture()
        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let mockProtocol = MockProtocolGen()
        let engine = FluidTranscriptionEngine()
        engine.modelVariant = "parakeet-tdt-0.6b-v2-coreml"

        // Use isolated speaker DB so test doesn't affect real data
        let testDB = tmpDir.appendingPathComponent("speakers_test.json")

        // swiftlint:disable trailing_closure
        let queue = PipelineQueue(
            transcriptionEngine: engine,
            diarizationFactory: { FluidDiarizer() },
            protocolGeneratorFactory: { mockProtocol },
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: true,
            micLabel: "Roman",
            speakerMatcherFactory: { SpeakerMatcher(dbPath: testDB) },
        )
        // swiftlint:enable trailing_closure

        // Auto-complete speaker naming with known names
        queue.speakerNamingHandler = { data in
            var mapping = data.mapping
            for label in mapping.keys where mapping[label] == label {
                mapping[label] = "TestSpeaker"
            }
            return .confirmed(mapping)
        }

        let loop = makeLoop(recorder: recorder, pipelineQueue: queue)

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        XCTAssertEqual(queue.jobs.count, 1)

        // Process the job (real transcription + real diarization)
        await queue.processNext()

        // Verify protocol was generated
        XCTAssertTrue(mockProtocol.generateCalled, "Protocol generator should have been called")
        XCTAssertEqual(queue.jobs[0].state, .done, "Job should complete with real diarization")

        // Verify transcript contains speaker names (not raw SPEAKER_0 labels)
        if let transcript = mockProtocol.capturedTranscript {
            XCTAssertFalse(transcript.isEmpty, "Transcript should not be empty")
            XCTAssertTrue(
                transcript.contains("TestSpeaker"),
                "Transcript should contain named speaker, got: \(transcript.prefix(300))",
            )
            XCTAssertFalse(
                transcript.contains("SPEAKER_"),
                "Transcript should not contain raw SPEAKER_ labels, got: \(transcript.prefix(300))",
            )
        }

        // Verify speaker DB was updated
        let matcher = SpeakerMatcher(dbPath: testDB)
        let stored = matcher.loadDB()
        XCTAssertFalse(stored.isEmpty, "Speaker DB should have been populated")
    }

    // MARK: - 8. WatchLoop Enqueues Job After Recording

    func testHandleMeetingEnqueuesJob() async throws {
        let mixPath = tmpDir.appendingPathComponent("test_mix.wav")
        let samples = [Float](repeating: 0.1, count: 48000)
        try AudioMixer.saveWAV(samples: samples, sampleRate: 48000, url: mixPath)

        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let queue = PipelineQueue(logDir: tmpDir)
        let loop = makeLoop(recorder: recorder, pipelineQueue: queue)

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        // Verify a job was enqueued
        XCTAssertEqual(queue.jobs.count, 1, "Should enqueue exactly one job")
        XCTAssertEqual(queue.jobs[0].meetingTitle, "Test Meeting")
        XCTAssertEqual(queue.jobs[0].appName, "Microsoft Teams")
        XCTAssertEqual(queue.jobs[0].state, .waiting)

        // Verify recorder was called
        XCTAssertTrue(recorder.startCalled)
        XCTAssertTrue(recorder.stopCalled)
    }
}
