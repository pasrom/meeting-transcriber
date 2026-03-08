import AVFoundation
import XCTest

@testable import MeetingTranscriber

// MARK: - Tests

@MainActor
final class WatchLoopE2ETests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchloop_e2e_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Ensure recordingsDir exists (handleMeeting writes intermediate 16kHz files there)
        try FileManager.default.createDirectory(
            at: DualSourceRecorder.recordingsDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tmpDir, FileManager.default.fileExists(atPath: tmpDir.path) {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Project root derived from #filePath (works in xctest, unlike Bundle.main).
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // MeetingTranscriber/
            .deletingLastPathComponent()  // app/
            .deletingLastPathComponent()  // Transcriber/
    }

    private func fixtureURL() -> URL {
        projectRoot
            .appendingPathComponent("tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("two_speakers_de.wav")
    }

    /// Upsample the fixture to 48kHz to simulate DualSourceRecorder output, save to tmpDir.
    private func prepare48kHzFixture(name: String = "mix.wav") throws -> URL {
        let fixture = fixtureURL()
        let samples = try AudioMixer.loadWAVAsFloat32(url: fixture)

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
            windowPID: pid
        )
    }

    /// Create a WatchLoop with injected mocks and immediate meeting-end detection.
    private func makeLoop(
        recorder: MockRecorder,
        diarization: MockDiarization = MockDiarization(),
        protocolGen: MockProtocolGen = MockProtocolGen(),
        whisperKit: WhisperKitEngine? = nil,
        diarizeEnabled: Bool = false,
        micLabel: String = "Roman"
    ) -> WatchLoop {
        let detector = MeetingDetector(patterns: AppMeetingPattern.all)
        // Meeting ends immediately (no windows)
        detector.windowListProvider = { [] }

        let engine = whisperKit ?? WhisperKitEngine()

        return WatchLoop(
            detector: detector,
            whisperKit: engine,
            recorderFactory: { recorder },
            diarizationFactory: { diarization },
            protocolGenerator: protocolGen,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 10,
            outputDir: tmpDir,
            diarizeEnabled: diarizeEnabled,
            micLabel: micLabel,
            noMic: false,
            claudeBin: "claude"
        )
    }

    // MARK: - 1. Full Pipeline: detect → record → transcribe → diarize → protocol

    func testFullPipelineDetectRecordTranscribeDiarizeProtocol() async throws {
        // Skip in CI (requires WhisperKit model download)
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires WhisperKit model download"
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)"
        )

        let mixPath = try prepare48kHzFixture()

        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let mockDiarization = MockDiarization()
        let mockProtocol = MockProtocolGen()

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        let loop = makeLoop(
            recorder: recorder,
            diarization: mockDiarization,
            protocolGen: mockProtocol,
            whisperKit: engine,
            diarizeEnabled: true
        )

        // Track state transitions
        var transitions: [(WatchLoop.State, WatchLoop.State)] = []
        loop.onStateChange = { old, new in
            transitions.append((old, new))
        }

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        // Verify state transitions
        let stateNames = transitions.map { "\($0.0) → \($0.1)" }
        XCTAssertTrue(
            stateNames.contains("idle → recording"),
            "Should transition to recording. Got: \(stateNames)"
        )
        XCTAssertTrue(
            stateNames.contains(where: { $0.contains("transcribing") }),
            "Should transition to transcribing. Got: \(stateNames)"
        )
        XCTAssertTrue(
            stateNames.contains(where: { $0.contains("generatingProtocol") }),
            "Should transition to generatingProtocol. Got: \(stateNames)"
        )

        // Verify recorder was called
        XCTAssertTrue(recorder.startCalled)
        XCTAssertTrue(recorder.stopCalled)

        // Verify diarization was called
        XCTAssertTrue(mockDiarization.runCalled, "Diarization should have been called")

        // Verify protocol generation
        XCTAssertTrue(mockProtocol.generateCalled, "Protocol generator should have been called")
        XCTAssertNotNil(mockProtocol.capturedTranscript)
        XCTAssertEqual(mockProtocol.capturedTitle, "Test Meeting")

        // Verify transcript has no Whisper special tokens
        if let transcript = mockProtocol.capturedTranscript {
            XCTAssertFalse(transcript.contains("<|"), "Transcript should not contain '<|'")
            XCTAssertFalse(transcript.contains("|>"), "Transcript should not contain '|>'")
        }

        // Verify transcript has speaker labels from diarization
        if let transcript = mockProtocol.capturedTranscript {
            XCTAssertTrue(
                transcript.contains("SPEAKER_"),
                "Transcript should contain SPEAKER_ labels after diarization. Got: \(transcript.prefix(500))"
            )
        }

        // Verify transcript contains timestamp format
        if let transcript = mockProtocol.capturedTranscript {
            XCTAssertTrue(
                transcript.contains("[00:"),
                "Transcript should contain timestamps. Got: \(transcript.prefix(300))"
            )
        }

        // Verify output files were saved
        let files = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        let txtFiles = files.filter { $0.pathExtension == "txt" }
        let mdFiles = files.filter { $0.pathExtension == "md" }
        XCTAssertFalse(txtFiles.isEmpty, "Should save a .txt transcript file")
        XCTAssertFalse(mdFiles.isEmpty, "Should save a .md protocol file")

        // Verify final state
        XCTAssertEqual(loop.state, .done)
        XCTAssertNotNil(loop.lastProtocolPath)
    }

    // MARK: - 2. Dual Source Transcription Path

    func testDualSourceTranscriptionPath() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires WhisperKit model download"
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)"
        )

        // Split fixture: first half = app, second half = mic
        let samples = try AudioMixer.loadWAVAsFloat32(url: fixture)
        let file = try AVAudioFile(forReading: fixture)
        let sourceRate = Int(file.processingFormat.sampleRate)

        let upsampled = sourceRate == 48000
            ? samples
            : AudioMixer.resample(samples, from: sourceRate, to: 48000)

        let midpoint = upsampled.count / 2
        let appSamples = Array(upsampled[..<midpoint])
        let micSamples = Array(upsampled[midpoint...])

        let appPath = tmpDir.appendingPathComponent("app.wav")
        let micPath = tmpDir.appendingPathComponent("mic.wav")
        let mixPath = tmpDir.appendingPathComponent("mix.wav")
        try AudioMixer.saveWAV(samples: upsampled, sampleRate: 48000, url: mixPath)
        try AudioMixer.saveWAV(samples: appSamples, sampleRate: 48000, url: appPath)
        try AudioMixer.saveWAV(samples: micSamples, sampleRate: 48000, url: micPath)

        let recorder = MockRecorder()
        recorder.mixPath = mixPath
        recorder.appPath = appPath
        recorder.micPath = micPath

        let mockProtocol = MockProtocolGen()

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        let loop = makeLoop(
            recorder: recorder,
            protocolGen: mockProtocol,
            whisperKit: engine,
            micLabel: "Roman"
        )

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        XCTAssertTrue(mockProtocol.generateCalled)
        if let transcript = mockProtocol.capturedTranscript {
            XCTAssertTrue(
                transcript.contains("Remote"),
                "Dual-source transcript should contain 'Remote' label for app audio. Got: \(transcript.prefix(500))"
            )
            XCTAssertTrue(
                transcript.contains("Roman"),
                "Dual-source transcript should contain mic label 'Roman'. Got: \(transcript.prefix(500))"
            )
        }
    }

    // MARK: - 3. Empty Transcript Transitions to Error

    func testEmptyTranscriptTransitionsToError() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires WhisperKit model download"
        )

        // Generate 1 second of silence at 48kHz
        let silenceSamples = [Float](repeating: 0, count: 48000)
        let silencePath = tmpDir.appendingPathComponent("silence.wav")
        try AudioMixer.saveWAV(samples: silenceSamples, sampleRate: 48000, url: silencePath)

        let recorder = MockRecorder()
        recorder.mixPath = silencePath

        let mockProtocol = MockProtocolGen()

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        let loop = makeLoop(
            recorder: recorder,
            protocolGen: mockProtocol,
            whisperKit: engine
        )

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        XCTAssertEqual(loop.state, .error, "State should be .error for empty transcript")
        XCTAssertEqual(loop.lastError, "Empty transcript")
        XCTAssertFalse(mockProtocol.generateCalled, "Protocol gen should NOT be called for empty transcript")
    }

    // MARK: - 4. Diarization Skipped When Not Available

    func testDiarizationSkippedWhenNotAvailable() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires WhisperKit model download"
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)"
        )

        let mixPath = try prepare48kHzFixture()

        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let mockDiarization = MockDiarization()
        mockDiarization.isAvailable = false  // Diarization NOT available

        let mockProtocol = MockProtocolGen()

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        let loop = makeLoop(
            recorder: recorder,
            diarization: mockDiarization,
            protocolGen: mockProtocol,
            whisperKit: engine,
            diarizeEnabled: true  // Enabled but not available
        )

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        // Pipeline should complete without diarization
        XCTAssertFalse(mockDiarization.runCalled, "Diarization should NOT be called when not available")
        XCTAssertTrue(mockProtocol.generateCalled, "Protocol should still be generated")
        XCTAssertEqual(loop.state, .done)
    }

    // MARK: - 5. Cooldown Prevents Re-detection After Handling

    func testCooldownPreventsRedetectionAfterHandling() {
        let detector = MeetingDetector(patterns: AppMeetingPattern.all, confirmationCount: 1)

        let teamsWindow: [String: Any] = [
            "kCGWindowOwnerName": "Microsoft Teams" as CFString,
            "kCGWindowName": "Standup | Microsoft Teams" as CFString,
            "kCGWindowOwnerPID": 1234 as CFNumber,
            "kCGWindowNumber": 1 as CFNumber,
            "kCGWindowBounds": [
                "X": 0, "Y": 0, "Width": 800, "Height": 600,
            ] as CFDictionary,
        ]

        detector.windowListProvider = { [teamsWindow] }

        // First detection succeeds
        let firstDetection = detector.checkOnce()
        XCTAssertNotNil(firstDetection, "Should detect meeting on first check")

        // Reset with cooldown
        detector.reset(appName: "Microsoft Teams")

        // Second detection should fail due to cooldown
        let secondDetection = detector.checkOnce()
        XCTAssertNil(secondDetection, "Should NOT detect meeting during cooldown")
    }

    // MARK: - 6. Resample Path Produces 16kHz for WhisperKit

    func testResamplePathProduces16kHzForWhisperKit() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires WhisperKit model download"
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)"
        )

        // Create 48kHz version
        let path48k = try prepare48kHzFixture(name: "resample_test.wav")

        // Resample to 16kHz (same path as handleMeeting)
        let samples48k = try AudioMixer.loadWAVAsFloat32(url: path48k)
        let resampled = AudioMixer.resample(samples48k, from: 48000, to: 16000)

        let path16k = tmpDir.appendingPathComponent("resample_test_16k.wav")
        try AudioMixer.saveWAV(samples: resampled, sampleRate: 16000, url: path16k)

        // Verify 16kHz file header
        let audioFile = try AVAudioFile(forReading: path16k)
        XCTAssertEqual(
            Int(audioFile.processingFormat.sampleRate), 16000,
            "Resampled file should be 16kHz"
        )

        // Verify WhisperKit can transcribe the 16kHz file
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        let transcript = try await engine.transcribe(audioPath: path16k)
        XCTAssertFalse(transcript.isEmpty, "WhisperKit should produce non-empty transcript from 16kHz audio")

        // Verify no special tokens
        XCTAssertFalse(transcript.contains("<|"), "Transcript should not contain '<|'")
        XCTAssertFalse(transcript.contains("|>"), "Transcript should not contain '|>'")
    }

    // MARK: - 7. Full Pipeline With Real Diarization (slow)

    func testFullPipelineWithRealDiarization() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping in CI: requires WhisperKit + pyannote"
        )

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)"
        )

        // Check real diarization availability using explicit project paths
        // (Bundle.main in xctest points to Xcode, not the project)
        let pythonPath = projectRoot.appendingPathComponent(".venv/bin/python")
        let scriptPath = projectRoot.appendingPathComponent("tools/diarize/diarize.py")
        let realDiarize = DiarizationProcess(pythonPath: pythonPath, scriptPath: scriptPath)
        try XCTSkipUnless(realDiarize.isAvailable, "Diarization not available (.venv/bin/python or tools/diarize/diarize.py not found)")

        // HF_TOKEN: try Keychain first, then .env file, then environment
        var hfToken = KeychainHelper.read(key: "HF_TOKEN")
            ?? ProcessInfo.processInfo.environment["HF_TOKEN"]
        if hfToken == nil {
            // Parse .env file from project root
            let envFile = projectRoot.appendingPathComponent(".env")
            if let contents = try? String(contentsOf: envFile, encoding: .utf8) {
                for line in contents.split(separator: "\n") {
                    if line.hasPrefix("HF_TOKEN=") {
                        hfToken = String(line.dropFirst("HF_TOKEN=".count))
                        // Set it so DiarizationProcess can pick it up via ProcessInfo.environment
                        setenv("HF_TOKEN", hfToken!, 1)
                        break
                    }
                }
            }
        }
        try XCTSkipUnless(hfToken != nil, "HF_TOKEN not found (Keychain, env var, or .env)")

        let mixPath = try prepare48kHzFixture()

        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let mockProtocol = MockProtocolGen()

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        let detector = MeetingDetector(patterns: AppMeetingPattern.all)
        detector.windowListProvider = { [] }

        let loop = WatchLoop(
            detector: detector,
            whisperKit: engine,
            recorderFactory: { recorder },
            diarizationFactory: { DiarizationProcess(pythonPath: pythonPath, scriptPath: scriptPath) },
            protocolGenerator: mockProtocol,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 10,
            outputDir: tmpDir,
            diarizeEnabled: true,
            micLabel: "Roman",
            noMic: false,
            claudeBin: "claude"
        )

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        // Verify protocol was generated with diarized transcript
        XCTAssertTrue(mockProtocol.generateCalled, "Protocol should be generated")
        if let transcript = mockProtocol.capturedTranscript {
            XCTAssertTrue(
                transcript.contains("SPEAKER_"),
                "Real diarization should produce SPEAKER_ labels. Got: \(transcript.prefix(500))"
            )
        }
        XCTAssertEqual(loop.state, .done)
    }
}
