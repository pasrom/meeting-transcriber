import AVFoundation
@testable import MeetingTranscriber
import XCTest

final class ResamplingIntegrationTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resample_integ_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    // swiftlint:disable:next unneeded_throws_rethrows
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
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

    // MARK: - Resampled output fed to pipeline with mock engine

    @MainActor
    func testResampledAudioFlowsThroughPipeline() async throws {
        let fixture = fixtureURL("two_speakers_de.m4a")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "Fixture not found")

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
        await queue.processNext()

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertEqual(engine.transcribeCallCount, 1)
        XCTAssertTrue(protocolGen.generateCalled)
        XCTAssertTrue(protocolGen.capturedTranscript?.contains("Resampled audio works") ?? false)
    }

    // MARK: - Dual-source resampling

    @MainActor
    func testDualSourceResamplingFlowsThroughPipeline() async throws {
        let fixture = fixtureURL("two_speakers_de.m4a")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "Fixture not found")

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
            mixPath: fixture,
            appPath: fixture,
            micPath: fixture,
            micDelay: 0,
        )
        queue.enqueue(job)
        await queue.processNext()

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertEqual(engine.transcribeCallCount, 2)
    }
}
