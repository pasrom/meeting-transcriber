import XCTest
@testable import MeetingTranscriber

final class WhisperKitEngineTests: XCTestCase {

    func testDefaultModel() {
        let engine = WhisperKitEngine()
        XCTAssertEqual(engine.modelVariant, "openai_whisper-large-v3-v20240930_turbo")
    }

    func testModelStateStartsUnloaded() {
        let engine = WhisperKitEngine()
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    func testDownloadProgressStartsAtZero() {
        let engine = WhisperKitEngine()
        XCTAssertEqual(engine.downloadProgress, 0, accuracy: 0.001)
    }

    func testLanguageDefault() {
        let engine = WhisperKitEngine()
        XCTAssertNil(engine.language, "Should auto-detect by default")
    }

    func testSetLanguage() {
        let engine = WhisperKitEngine()
        engine.language = "de"
        XCTAssertEqual(engine.language, "de")
    }

    /// Integration test: downloads whisper-small model and transcribes a German audio fixture.
    func testTranscribeGermanAudio() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("two_speakers_de.wav")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)"
        )

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        let transcript = try await engine.transcribe(audioPath: fixture)

        XCTAssertFalse(transcript.isEmpty, "Transcript should not be empty")

        // Should contain timestamp format [MM:SS]
        let timestampRegex = try NSRegularExpression(pattern: #"\[\d{2}:\d{2}\]"#)
        let hasTimestamp = timestampRegex.firstMatch(
            in: transcript,
            range: NSRange(transcript.startIndex..., in: transcript)
        ) != nil
        XCTAssertTrue(
            hasTimestamp,
            "Transcript should contain timestamps in [MM:SS] format, got: \(transcript)"
        )

        // Should contain some German words from the conversation
        let lowered = transcript.lowercased()
        let germanWords = ["und", "die", "der", "ist", "wir", "das", "den", "ich", "nicht", "ein"]
        let foundGerman = germanWords.contains { lowered.contains($0) }
        XCTAssertTrue(
            foundGerman,
            "Transcript should contain German words, got: \(transcript)"
        )
    }
}
