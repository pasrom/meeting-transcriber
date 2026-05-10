@testable import MeetingTranscriber
import XCTest

/// Production-model WhisperKit quality tests. Skipped by default — gated by
/// `RUN_QUALITY_TESTS=1` so a normal `swift test` run on a dev machine
/// doesn't pull a 1+ GB model. CI's quality-baseline job sets the env var.
///
/// Computes WER per fixture and appends rows to `QualityResultsWriter`.
/// Diarization (DER) lives in a sibling class.
@MainActor
final class WhisperKitQualityTests: XCTestCase {
    private var modelVariant: String {
        ProcessInfo.processInfo.environment["WHISPERKIT_MODEL"]
            ?? "openai_whisper-large-v3-v20240930_turbo"
    }

    func test_whisperKit_twoSpeakers_de_wer() async throws {
        try skipUnlessQualityRun()
        try await runFixture(named: "two_speakers_de")
    }

    func test_whisperKit_threeSpeakers_de_wer() async throws {
        try skipUnlessQualityRun()
        try await runFixture(named: "three_speakers_de")
    }

    // Soft threshold of 0.5 catches catastrophic breakage (corrupted model,
    // audio not loaded, biasing prompt destroying decoding) but stays well
    // above the production baseline (~0.23-0.29 with explicit `language=de`).
    private func runFixture(named name: String) async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = modelVariant
        engine.language = "de"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "WhisperKit model failed to load")

        try await runWERAgainstFixture(
            named: name,
            engine: engine,
            engineLabel: "whisperKit",
            modelVariant: modelVariant,
            threshold: 0.5,
        )
    }
}
