import AVFoundation
@testable import MeetingTranscriber
import XCTest

@MainActor
final class ParakeetE2ETests: XCTestCase {
    // MARK: - Model loading

    func testParakeetModelLoadsSuccessfully() async throws {
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires Parakeet model download")

        let engine = ParakeetEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")
    }

    // MARK: - Transcription with fixture

    func testTranscribeSegmentsWithFixture() async throws {
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires Parakeet model download")

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let engine = ParakeetEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        // Resample 48kHz fixture to 16kHz for Parakeet
        let resampled16k = try resampleFixtureToTemp(fixture)
        defer { try? FileManager.default.removeItem(at: resampled16k.deletingLastPathComponent()) }

        let segments = try await engine.transcribeSegments(audioPath: resampled16k)

        XCTAssertFalse(segments.isEmpty, "Should produce at least one segment")

        // Verify timestamps are non-negative and ordered
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.start, 0, "Start should be non-negative")
            XCTAssertGreaterThanOrEqual(segment.end, segment.start, "End should be >= start")
        }

        // Verify text is non-empty per segment
        for segment in segments {
            XCTAssertFalse(segment.text.isEmpty, "Segment text should not be empty")
        }
    }

    func testTranscribeSegmentsProducesGermanContent() async throws {
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires Parakeet model download")

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let engine = ParakeetEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        // Resample 48kHz fixture to 16kHz for Parakeet
        let resampled16k = try resampleFixtureToTemp(fixture)
        defer { try? FileManager.default.removeItem(at: resampled16k.deletingLastPathComponent()) }

        let segments = try await engine.transcribeSegments(audioPath: resampled16k)
        XCTAssertFalse(segments.isEmpty, "Should produce at least one segment")

        let fullText = segments.map(\.text).joined(separator: " ")
        assertTranscriptContent(fullText)
    }

    func testTranscribeSegmentsGroupsIntoSentences() async throws {
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires Parakeet model download")

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let engine = ParakeetEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        // Resample 48kHz fixture to 16kHz for Parakeet
        let resampled16k = try resampleFixtureToTemp(fixture)
        defer { try? FileManager.default.removeItem(at: resampled16k.deletingLastPathComponent()) }

        let segments = try await engine.transcribeSegments(audioPath: resampled16k)

        // The fixture has two speakers with multiple sentences — expect more than one segment
        XCTAssertGreaterThan(
            segments.count, 1,
            "Should produce multiple segments, not just one giant segment (got \(segments.count))",
        )
    }

    // MARK: - Progress tracking

    func testDownloadProgressReachesOne() async throws {
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires Parakeet model download")

        let engine = ParakeetEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")
        XCTAssertEqual(engine.downloadProgress, 1.0, "Download progress should be 1.0 after model load")
    }

    func testTranscriptionProgressReachesOne() async throws {
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires Parakeet model download")

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let engine = ParakeetEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        // Resample 48kHz fixture to 16kHz for Parakeet
        let resampled16k = try resampleFixtureToTemp(fixture)
        defer { try? FileManager.default.removeItem(at: resampled16k.deletingLastPathComponent()) }

        _ = try await engine.transcribeSegments(audioPath: resampled16k)
        XCTAssertEqual(
            engine.transcriptionProgress, 1.0,
            "Transcription progress should be 1.0 after transcribeSegments completes",
        )
    }

    // MARK: - Helpers

    /// Keywords expected in the fixture's German transcript.
    private let expectedKeywords = [
        "willkommen", "Projekt", "Status", "Entwicklung", "Zeitplan",
    ]

    private func assertTranscriptContent(_ transcript: String) {
        let lower = transcript.lowercased()
        var matched = 0
        for keyword in expectedKeywords where lower.contains(keyword.lowercased()) {
            matched += 1
        }
        // At least 3 of 5 keywords should appear
        XCTAssertGreaterThanOrEqual(
            matched, 3,
            "Expected at least 3 of \(expectedKeywords) in transcript, found \(matched). Transcript:\n\(transcript)",
        )
    }

    private func fixtureURL(_ name: String = "two_speakers_de.wav") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    /// Resample the 48kHz fixture to a 16kHz temp WAV file for Parakeet.
    private func resampleFixtureToTemp(_ fixture: URL) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet_e2e_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let resampled16k = tmpDir.appendingPathComponent("resampled_16k.wav")

        let samples = try AudioMixer.loadAudioFileAsFloat32(url: fixture)
        XCTAssertFalse(samples.isEmpty, "Should load samples from fixture")

        let file = try AVAudioFile(forReading: fixture)
        let sourceSampleRate = Int(file.processingFormat.sampleRate)
        let targetRate = 16000

        let resampled: [Float]
        if sourceSampleRate != targetRate {
            resampled = AudioMixer.resample(samples, from: sourceSampleRate, to: targetRate)
            XCTAssertFalse(resampled.isEmpty, "Resampled audio should not be empty")
        } else {
            resampled = samples
        }

        try AudioMixer.saveWAV(samples: resampled, sampleRate: targetRate, url: resampled16k)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resampled16k.path))

        return resampled16k
    }
}
