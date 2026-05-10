@testable import MeetingTranscriber
import XCTest

/// Production-model Qwen3-ASR quality tests. Skipped by default — gated by
/// `RUN_QUALITY_TESTS=1` so a normal `swift test` run on a dev machine
/// doesn't pull the ~1.75 GB CoreML f32 bundle. CI's quality job sets the
/// env var.
///
/// Computes WER per fixture and appends rows to `QualityResultsWriter`.
/// Pairs with `WhisperKitQualityTests` (Whisper) and `ParakeetQualityTests`
/// so a single quality artifact contains baselines across all three ASR
/// engines plus the diarizer DER rows.
///
/// Class-level `@available(macOS 15, *)` mirrors `Qwen3AsrEngine`'s gate
/// (CoreML stateful models require macOS 15). The annotation is runtime-only
/// — the file compiles fine against the package's macOS 14 deployment
/// target; XCTest just skips the methods on macOS 14 hosts at discovery
/// time.
@available(macOS 15, *)
@MainActor
final class Qwen3AsrEngineQualityTests: XCTestCase {
    func test_qwen3_twoSpeakers_de_wer() async throws {
        try skipUnlessQualityRun()
        try await runFixture(named: "two_speakers_de")
    }

    func test_qwen3_threeSpeakers_de_wer() async throws {
        try skipUnlessQualityRun()
        try await runFixture(named: "three_speakers_de")
    }

    // Threshold 0.6 sits ~10 % above the current baselines (two ≈ 0.32,
    // three ≈ 0.51 as of 2026-05-10) — wide enough to absorb run-to-run
    // variance, tight enough to flag catastrophic breakage. Qwen3 does
    // accept an explicit `language="de"` hint (unlike Parakeet's
    // auto-detect-only contract), but the model still misrecognises proper
    // nouns + tech jargon on the three-speaker fixture, lifting WER above
    // WhisperKit's level.
    //
    // Round-trips the fixture through `AudioMixer.loadAudioFileAsFloat32`
    // → `AudioMixer.saveWAV` before transcription. Without this, the Mini
    // CI run produced garbage tokens (single Cyrillic chars / punctuation)
    // even though the fixture is already 16 kHz mono PCM. The same
    // round-trip is what `Qwen3E2ETests` does, and that test runs green
    // on Mini against the top-level fixture. Cause not yet root-caused,
    // but mirroring the working test's ingestion path normalises whatever
    // Qwen3's loader is choking on.
    private func runFixture(named name: String) async throws {
        let truth = try GroundTruth.load(named: name)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: truth.audioURL.path),
            "Audio fixture missing: \(truth.audioURL.path)",
        )

        let tmpDir = try makeTempDirectory(prefix: "qwen3_quality")
        let resampled16k = tmpDir.appendingPathComponent("resampled_16k.wav")
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: truth.audioURL)
        try AudioMixer.saveWAV(
            samples: samples,
            sampleRate: AudioConstants.targetSampleRate,
            url: resampled16k,
        )

        let engine = Qwen3AsrEngine()
        engine.language = "de"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Qwen3-ASR model failed to load")

        try await runWERAgainstFixture(
            named: name,
            engine: engine,
            engineLabel: "qwen3",
            modelVariant: nil,
            threshold: 0.6,
            audioPathOverride: resampled16k,
        )
    }
}
