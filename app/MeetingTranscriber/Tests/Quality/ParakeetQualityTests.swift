@testable import MeetingTranscriber
import XCTest

/// Production-model Parakeet quality tests. Skipped by default — gated by
/// `RUN_QUALITY_TESTS=1` so a normal `swift test` run on a dev machine
/// doesn't pull the ~50 MB FluidAudio model bundle. CI's quality job sets
/// the env var.
///
/// Computes WER per fixture and appends rows to `QualityResultsWriter`.
/// Pairs with `WhisperKitQualityTests` (Whisper) so a single quality artifact
/// contains baselines across the ASR engines plus the diarizer DER rows.
///
/// Parakeet auto-detects language — there's no `engine.language = "de"`
/// equivalent. As of 2026-05-10, WER on the German fixtures runs ~0.45-0.46
/// vs WhisperKit's ~0.23-0.29 with explicit `language="de"`. Auto-detect on
/// short (<30 s) German audio is the likely cause; the numbers are still
/// useful as a regression baseline, just don't read them as quality parity.
@MainActor
final class ParakeetQualityTests: XCTestCase {
    func test_parakeet_twoSpeakers_de_wer() async throws {
        try skipUnlessQualityRun()
        try await runFixture(named: "two_speakers_de")
    }

    func test_parakeet_threeSpeakers_de_wer() async throws {
        try skipUnlessQualityRun()
        try await runFixture(named: "three_speakers_de")
    }

    // Threshold 0.6 sits ~12-15 % above the current baseline (~0.45-0.46) so
    // the test catches catastrophic breakage (model corrupted, language
    // auto-detect misfiring, audio not loaded) without flapping on minor
    // variance.
    private func runFixture(named name: String) async throws {
        let engine = ParakeetEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Parakeet model failed to load")

        try await runWERAgainstFixture(
            named: name,
            engine: engine,
            engineLabel: "parakeet",
            modelVariant: nil,
            threshold: 0.6,
        )
    }
}
