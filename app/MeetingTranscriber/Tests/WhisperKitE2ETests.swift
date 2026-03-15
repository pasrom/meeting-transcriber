import AVFoundation
@testable import MeetingTranscriber
import XCTest

@MainActor
final class WhisperKitE2ETests: XCTestCase {
    // MARK: - stripWhisperTokens (no model needed, always run)

    func testStripWhisperTokensStartOfTranscript() {
        let input = "<|startoftranscript|>Hello world"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Hello world")
    }

    func testStripWhisperTokensEndOfText() {
        let input = "Hello world<|endoftext|>"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Hello world")
    }

    func testStripWhisperTokensLanguageTag() {
        let input = "<|en|>Hello world"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Hello world")
    }

    func testStripWhisperTokensGermanLanguageTag() {
        let input = "<|de|>Hallo Welt"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Hallo Welt")
    }

    func testStripWhisperTokensTimestampTokens() {
        let input = "<|0.00|>Hello<|2.50|> world<|5.00|>"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Hello world")
    }

    func testStripWhisperTokensMultipleTokens() {
        let input = "<|startoftranscript|><|en|><|0.00|>Hello world<|2.50|><|endoftext|>"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Hello world")
    }

    func testStripWhisperTokensNoTokens() {
        let input = "Plain text without any tokens"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Plain text without any tokens")
    }

    func testStripWhisperTokensEmptyString() {
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(""), "")
    }

    func testStripWhisperTokensOnlyTokens() {
        let input = "<|startoftranscript|><|en|><|endoftext|>"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "")
    }

    func testStripWhisperTokensPreservesNormalAngleBrackets() {
        let input = "2 < 3 and 5 > 4"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "2 < 3 and 5 > 4")
    }

    func testStripWhisperTokensTranslateToken() {
        let input = "<|translate|>Some text"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Some text")
    }

    func testStripWhisperTokensTranscribeToken() {
        let input = "<|transcribe|>Some text"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Some text")
    }

    func testStripWhisperTokensNotimeStampsToken() {
        let input = "<|notimestamps|>Some text"
        XCTAssertEqual(WhisperKitEngine.stripWhisperTokens(input), "Some text")
    }

    func testStripWhisperTokensMixedContent() {
        let input = "<|0.00|>Guten Tag,<|1.20|> wie geht es Ihnen?<|3.50|>"
        let result = WhisperKitEngine.stripWhisperTokens(input)
        XCTAssertEqual(result, "Guten Tag, wie geht es Ihnen?")
        XCTAssertFalse(result.contains("<|"))
        XCTAssertFalse(result.contains("|>"))
    }

    // MARK: - Verify transcript output has no special tokens

    func testTranscriptOutputContainsNoSpecialTokens() {
        // Simulate what transcribe() does: strip tokens then trim
        let rawSegments = [
            "<|startoftranscript|><|de|><|0.00|>Hallo zusammen<|2.50|>",
            "<|2.50|>Wie geht es euch?<|5.00|>",
            "<|5.00|>Gut, danke.<|7.00|><|endoftext|>",
        ]

        for raw in rawSegments {
            let cleaned = WhisperKitEngine.stripWhisperTokens(raw)
                .trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(
                cleaned.contains("<|"),
                "Cleaned text should not contain '<|': \(cleaned)",
            )
            XCTAssertFalse(
                cleaned.contains("|>"),
                "Cleaned text should not contain '|>': \(cleaned)",
            )
        }
    }

    // MARK: - Resample 48kHz -> 16kHz (no model needed)

    func testResample48kTo16k() {
        // Generate a simple sine wave at 48kHz
        let sourceRate = 48000
        let targetRate = 16000
        let duration = 1.0 // 1 second
        let sampleCount = Int(duration * Double(sourceRate))

        var samples = [Float](repeating: 0, count: sampleCount)
        let frequency: Float = 440.0 // A4
        for i in 0 ..< sampleCount {
            samples[i] = sin(2 * .pi * frequency * Float(i) / Float(sourceRate))
        }

        let resampled = AudioMixer.resample(samples, from: sourceRate, to: targetRate)

        // Output should have approximately targetRate samples for 1 second
        let expectedCount = Int(duration * Double(targetRate))
        XCTAssertEqual(
            resampled.count,
            expectedCount,
            "Resampled should have \(expectedCount) samples, got \(resampled.count)",
        )
        XCTAssertFalse(resampled.isEmpty)
    }

    func testResamplePreservesSignalEnergy() {
        let sourceRate = 48000
        let targetRate = 16000
        let sampleCount = sourceRate // 1 second

        // Generate a 440Hz sine wave
        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0 ..< sampleCount {
            samples[i] = sin(2 * .pi * 440 * Float(i) / Float(sourceRate))
        }

        let resampled = AudioMixer.resample(samples, from: sourceRate, to: targetRate)

        // Compute RMS of both
        let sourceRMS = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let targetRMS = sqrt(resampled.map { $0 * $0 }.reduce(0, +) / Float(resampled.count))

        // RMS should be similar (within 10%)
        XCTAssertEqual(
            Double(targetRMS),
            Double(sourceRMS),
            accuracy: Double(sourceRMS) * 0.1,
            "Resampled signal RMS should be close to original",
        )
    }

    // MARK: - Integration: transcribeSegments with real audio (slow, needs model)

    func testTranscribeSegmentsWithFixture() async throws {
        // This test downloads a WhisperKit model (~1GB) - skip in CI
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires WhisperKit model download")

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        let segments = try await engine.transcribeSegments(audioPath: fixture)

        XCTAssertFalse(segments.isEmpty, "Should produce at least one segment")

        // Verify no segment contains Whisper special tokens
        for segment in segments {
            XCTAssertFalse(
                segment.text.contains("<|"),
                "Segment text should not contain '<|': \(segment.text)",
            )
            XCTAssertFalse(
                segment.text.contains("|>"),
                "Segment text should not contain '|>': \(segment.text)",
            )
        }

        // Verify timestamps are non-negative and ordered
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.start, 0, "Start should be non-negative")
            XCTAssertGreaterThanOrEqual(segment.end, segment.start, "End should be >= start")
        }

        // Verify text is non-empty after stripping
        for segment in segments {
            XCTAssertFalse(segment.text.isEmpty, "Segment text should not be empty")
        }
    }

    func testTranscribeSegmentsHallucinationFilter() async throws {
        // This test downloads a WhisperKit model (~1GB) - skip in CI
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires WhisperKit model download")

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        let segments = try await engine.transcribeSegments(audioPath: fixture)

        // Verify no consecutive segments have identical text (hallucination filter)
        for i in 1 ..< segments.count {
            XCTAssertNotEqual(
                segments[i].text, segments[i - 1].text,
                "Consecutive segments should not have identical text (hallucination)",
            )
        }
    }

    func testFullDualSourcePipeline() async throws {
        // This test downloads a WhisperKit model (~1GB) - skip in CI
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires WhisperKit model download")

        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )

        // Load fixture, resample 48kHz->16kHz, save as temp file, then transcribe
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: fixture)
        XCTAssertFalse(samples.isEmpty, "Should load samples from fixture")

        // Determine source sample rate from AVAudioFile
        let file = try AVAudioFile(forReading: fixture)
        let sourceSampleRate = Int(file.processingFormat.sampleRate)

        // Resample to 16kHz if needed
        let targetRate = 16000
        let resampled: [Float]
        if sourceSampleRate != targetRate {
            resampled = AudioMixer.resample(samples, from: sourceSampleRate, to: targetRate)
            XCTAssertFalse(resampled.isEmpty, "Resampled audio should not be empty")
        } else {
            resampled = samples
        }

        // Save resampled audio to temp file
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit_e2e_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tmpWAV = tmpDir.appendingPathComponent("resampled_16k.wav")
        try AudioMixer.saveWAV(samples: resampled, sampleRate: targetRate, url: tmpWAV)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpWAV.path))

        // Transcribe the resampled file
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        let transcript = try await engine.transcribe(audioPath: tmpWAV)

        XCTAssertFalse(transcript.isEmpty, "Transcript should not be empty")

        // Verify no special tokens in output
        XCTAssertFalse(transcript.contains("<|"), "Transcript should not contain '<|'")
        XCTAssertFalse(transcript.contains("|>"), "Transcript should not contain '|>'")

        // Verify timestamp format
        let lines = transcript.components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 0, "Should have at least one line")
        for line in lines where !line.isEmpty {
            XCTAssertTrue(
                line.hasPrefix("["),
                "Each line should start with timestamp bracket: \(line)",
            )
        }
    }

    // MARK: - Multi-format E2E (resample + transcribe from MP3/M4A/MP4)

    /// Transcribe a multi-format file end-to-end: load → resample → transcribe → verify.
    /// Returns the transcript for cross-format comparison.
    private func transcribeFixture(_ filename: String, engine: WhisperKitEngine) async throws -> String {
        let fixture = fixtureURL(filename)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Fixture \(filename) not found",
        )

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiformat_e2e_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // resampleFile uses loadAudioAsFloat32 → AVAudioFile or AVAsset fallback
        let resampled16k = tmpDir.appendingPathComponent("resampled_16k.wav")
        try await AudioMixer.resampleFile(from: fixture, to: resampled16k, targetRate: 16000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resampled16k.path))

        // Verify output is 16kHz
        let outFile = try AVAudioFile(forReading: resampled16k)
        XCTAssertEqual(Int(outFile.processingFormat.sampleRate), 16000)

        let transcript = try await engine.transcribe(audioPath: resampled16k)
        XCTAssertFalse(transcript.isEmpty, "\(filename): transcript should not be empty")
        XCTAssertFalse(transcript.contains("<|"), "\(filename): no special tokens")
        return transcript
    }

    /// Keywords expected in the transcript (from the fixture's TTS content).
    /// The fixture contains: "Guten Tag, willkommen zum Projekt Meeting",
    /// "Danke ... aktuellen Status berichten", "Wie läuft die Entwicklung",
    /// "Entwicklung läuft nach Plan ... Zeitplan".
    /// We check case-insensitively for key words that WhisperKit reliably recognizes.
    private let expectedKeywords = [
        "willkommen", "Projekt", "Status", "Entwicklung", "Zeitplan",
    ]

    private func assertTranscriptContent(_ transcript: String, format: String) {
        let lower = transcript.lowercased()
        var matched = 0
        for keyword in expectedKeywords where lower.contains(keyword.lowercased()) {
            matched += 1
        }
        // At least 3 of 5 keywords should appear (TTS + compression may cause minor variations)
        XCTAssertGreaterThanOrEqual(
            matched, 3,
            "\(format): expected at least 3 of \(expectedKeywords) in transcript, found \(matched). Transcript:\n\(transcript)",
        )
    }

    func testTranscribeMultiFormatContent() async throws {
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        try XCTSkipIf(isCI, "Skipping in CI: requires WhisperKit model download")

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)

        let wavTranscript = try await transcribeFixture("two_speakers_de.wav", engine: engine)
        let mp3Transcript = try await transcribeFixture("two_speakers_de.mp3", engine: engine)
        let m4aTranscript = try await transcribeFixture("two_speakers_de.m4a", engine: engine)
        let mp4Transcript = try await transcribeFixture("two_speakers_de.mp4", engine: engine)

        // Verify each format produces the expected German content
        assertTranscriptContent(wavTranscript, format: "WAV")
        assertTranscriptContent(mp3Transcript, format: "MP3")
        assertTranscriptContent(m4aTranscript, format: "M4A")
        assertTranscriptContent(mp4Transcript, format: "MP4")
    }

    // MARK: - Helpers

    private func fixtureURL(_ name: String = "two_speakers_de.wav") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }
}
