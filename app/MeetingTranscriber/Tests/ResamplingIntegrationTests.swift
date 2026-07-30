import AVFoundation
@testable import MeetingTranscriber
import XCTest

final class ResamplingIntegrationTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "resample_integ")
    }

    /// Copy a fixture into the test's tmpDir. Kept for pipeline tests as a
    /// safety margin: `persistAudioToOutput` only relocates sources inside the
    /// staging dir, so a Fixtures/ path is left alone today, but a test that
    /// points staging at its own tmpDir would delete the shared asset.
    private func copyFixtureIntoTmp(_ name: String) throws -> URL {
        let src = fixtureURL(name)
        let dst = tmpDir.appendingPathComponent("\(UUID().uuidString)_\(name)")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    // MARK: - WAV resampling produces valid 16kHz output

    func testResampleWAVFixtureTo16kHz() async throws {
        let fixture = fixtureURL("three_speakers_de.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "Fixture not found")

        let output = tmpDir.appendingPathComponent("resampled.wav")
        try await AudioMixer.resampleFile(from: fixture, to: output)

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Int(file.processingFormat.sampleRate), 16000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
    }

    // MARK: - M4A resampling (AVAsset fallback path)

    func testResampleM4AFixtureTo16kHz() async throws {
        let fixture = fixtureURL("two_speakers_de.m4a")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "Fixture not found")

        let output = tmpDir.appendingPathComponent("resampled.wav")
        try await AudioMixer.resampleFile(from: fixture, to: output)

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Int(file.processingFormat.sampleRate), 16000)
        XCTAssertGreaterThan(file.length, 0)
    }

    // MARK: - MP3 resampling

    func testResampleMP3FixtureTo16kHz() async throws {
        let fixture = fixtureURL("two_speakers_de.mp3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "Fixture not found")

        let output = tmpDir.appendingPathComponent("resampled.wav")
        try await AudioMixer.resampleFile(from: fixture, to: output)

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Int(file.processingFormat.sampleRate), 16000)
        XCTAssertGreaterThan(file.length, 0)
    }

    // MARK: - Phone / messenger voice formats

    /// Opus arrives at 48 kHz, so the import must decode and downsample it. A
    /// byte copy would leave the output at 48 kHz.
    func testResampleOpusFixtureTo16kHz() async throws {
        let fixture = fixtureURL("two_speakers_de.opus")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "Fixture not found")

        let output = tmpDir.appendingPathComponent("resampled.wav")
        try await AudioMixer.resampleFile(from: fixture, to: output)

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Int(file.processingFormat.sampleRate), 16000)
        XCTAssertGreaterThan(file.length, 0)
    }

    // MARK: - Resampled output fed to pipeline with mock engine

    /// A voice memo in a container Apple's frameworks decode (not ffmpeg) must
    /// survive the whole queue. The engine is stubbed, so what this covers is the
    /// import chain around it: decode, downsample to 16 kHz, persist.
    @MainActor
    func testOpusImportFlowsThroughPipeline() async throws {
        let fixtureSrc = fixtureURL("two_speakers_de.opus")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixtureSrc.path), "Fixture not found")
        let mixPath = try copyFixtureIntoTmp("two_speakers_de.opus")

        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Voice memo content"),
        ]
        let protocolGen = MockProtocolGen()

        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
        )

        queue.enqueue(PipelineJob(
            meetingTitle: "Voice Memo",
            appName: "Test",
            mixPath: mixPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        ))
        await queue.awaitProcessing()

        let result = queue.jobs.first
        XCTAssertEqual(result?.state, .done, "pipeline error: \(result?.error ?? "nil")")
        XCTAssertTrue(protocolGen.capturedTranscript?.contains("Voice memo content") ?? false)

        let persisted = try FileManager.default
            .contentsOfDirectory(at: tmpDir.appendingPathComponent("recordings"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("_16k.wav") }
        let audio16k = try XCTUnwrap(persisted.first, "no 16 kHz audio persisted for the import")
        let file = try AVAudioFile(forReading: audio16k)
        XCTAssertEqual(Int(file.processingFormat.sampleRate), AudioConstants.targetSampleRate)
        XCTAssertGreaterThan(file.length, 0)
    }

    @MainActor
    func testResampledAudioFlowsThroughPipeline() async throws {
        let fixtureSrc = fixtureURL("two_speakers_de.m4a")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixtureSrc.path), "Fixture not found")
        let fixture = try copyFixtureIntoTmp("two_speakers_de.m4a")

        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Resampled audio works"),
        ]
        let protocolGen = MockProtocolGen()

        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
        )

        let job = PipelineJob(
            meetingTitle: "Resample Test",
            appName: "Test",
            mixPath: fixture,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue.enqueue(job)
        await queue.awaitProcessing()

        let result = queue.jobs.first
        XCTAssertEqual(result?.state, .done, "pipeline error: \(result?.error ?? "nil")")
        XCTAssertEqual(engine.transcribeCallCount, 1)
        XCTAssertTrue(protocolGen.generateCalled)
        XCTAssertTrue(protocolGen.capturedTranscript?.contains("Resampled audio works") ?? false)
    }

    // MARK: - Dual-source resampling

    @MainActor
    func testDualSourceResamplingFlowsThroughPipeline() async throws {
        let fixtureSrc = fixtureURL("two_speakers_de.m4a")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixtureSrc.path), "Fixture not found")
        // Each track gets its own copy: the persist step handles the mix, app
        // and mic paths one by one, so several pointing at the same URL is the
        // shape that used to destroy the source.
        let mixPath = try copyFixtureIntoTmp("two_speakers_de.m4a")
        let appPath = try copyFixtureIntoTmp("two_speakers_de.m4a")
        let micPath = try copyFixtureIntoTmp("two_speakers_de.m4a")

        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Track content"),
        ]
        let protocolGen = MockProtocolGen()

        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
        )

        let job = PipelineJob(
            meetingTitle: "Dual Resample",
            appName: "Test",
            mixPath: mixPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: 0,
        )
        queue.enqueue(job)
        await queue.awaitProcessing()

        let result = queue.jobs.first
        XCTAssertEqual(result?.state, .done, "pipeline error: \(result?.error ?? "nil")")
        XCTAssertEqual(engine.transcribeCallCount, 2)
    }
}
