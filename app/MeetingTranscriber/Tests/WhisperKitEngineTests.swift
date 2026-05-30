@testable import MeetingTranscriber
import WhisperKit
import XCTest

@MainActor
final class WhisperKitEngineTests: XCTestCase {
    /// Regression for #339: "Auto-detect" (language == nil) silently fell back
    /// to English because WhisperKit's `DecodingOptions.detectLanguage` defaults
    /// to `!usePrefillPrompt` (= false), so the language-detection path in
    /// TranscribeTask was skipped and the output defaulted to "en".
    func testAutoDetectEnablesLanguageDetection() {
        let options = WhisperKitEngine.decodingOptions(language: nil)
        XCTAssertNil(options.language, "Auto-detect must not pin a language")
        XCTAssertTrue(
            options.detectLanguage,
            "Auto-detect (language == nil) must enable WhisperKit language detection, "
                + "otherwise transcription falls back to English",
        )
    }

    /// When an explicit language is chosen, detection must stay off so the
    /// user's choice is honoured verbatim.
    func testExplicitLanguageDisablesDetection() {
        let options = WhisperKitEngine.decodingOptions(language: "pl")
        XCTAssertEqual(options.language, "pl")
        XCTAssertFalse(
            options.detectLanguage,
            "An explicit language must not trigger auto-detection",
        )
    }

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
        let fixture = fixtureURL()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
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
            range: NSRange(transcript.startIndex..., in: transcript),
        ) != nil
        XCTAssertTrue(
            hasTimestamp,
            "Transcript should contain timestamps in [MM:SS] format, got: \(transcript)",
        )

        // Should contain some German words from the conversation
        let lowered = transcript.lowercased()
        let germanWords = ["und", "die", "der", "ist", "wir", "das", "den", "ich", "nicht", "ein", "guten", "tag"]
        let foundGerman = germanWords.contains { lowered.contains($0) }
        XCTAssertTrue(
            foundGerman,
            "Transcript should contain German words, got: \(transcript)",
        )
    }

    /// Streaming entry point: same fixture, fed as a raw 16 kHz Float32
    /// buffer through `transcribeSamples` — the path `StreamingTranscriber`
    /// uses to hand VAD-windowed slices into WhisperKit during live
    /// captions. Verifies the `StreamingTranscribingEngine` conformance
    /// actually produces text on real audio (not just routes through the
    /// type system).
    func testTranscribeSamplesGermanAudio() async throws {
        let fixture = fixtureURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)

        let (raw, srcRate) = try await AudioMixer.loadAudioAsFloat32(url: fixture)
        let mono16k = srcRate == 16000 ? raw : AudioMixer.resample(raw, from: srcRate, to: 16000)
        // First ~5 s of the fixture — enough to produce text, fast to transcribe.
        let clip = Array(mono16k.prefix(16000 * 5))

        let text = try await engine.transcribeSamples(clip)
        XCTAssertFalse(text.isEmpty, "Streaming transcription should produce non-empty text")

        let lowered = text.lowercased()
        let germanWords = ["und", "die", "der", "ist", "wir", "das", "den", "ich", "nicht", "ein", "guten", "tag"]
        XCTAssertTrue(
            germanWords.contains { lowered.contains($0) },
            "Streaming transcript should contain German words, got: \(text)",
        )
    }
}
