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

    /// Real recorded meeting, four speakers, roughly a third of it overlapping.
    /// Measured 0.29, so the same 0.5 bound the synthetic fixtures use fits
    /// without loosening. The errors are shaped differently though: 73 of the
    /// 97 are DELETIONS rather than substitutions.
    ///
    /// Two causes are mixed in that figure and this fixture cannot separate
    /// them. Speech really is lost when someone talks over it, but the
    /// reference also concatenates overlapping turns in start-time order while
    /// the engine emits them in acoustic order, and the alignment charges that
    /// mismatch as deletions too. Either way the synthetic fixtures, which have
    /// no overlap at all, cannot produce the shape.
    func test_whisperKit_fourSpeakers_en_real_wer() async throws {
        try skipUnlessQualityRun()
        try await runFixture(named: "four_speakers_en_ami", language: "en")
    }

    /// Reports the experimental prompt's real-model trade-off without gating it.
    /// The default unprompted path remains protected by the ordinary fixture
    /// baselines above. This opt-in path instead records WER, added deletions,
    /// and end-of-audio coverage so its user-facing warning can be kept honest.
    func test_whisperKit_enabledVocabularyPrompt_reportsDenseFixtureTradeoff() async throws {
        try skipUnlessQualityRun()
        let truth = try GroundTruth.load(named: "four_speakers_en_ami")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: truth.audioURL.path))

        let vocabularyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-vocabulary-\(UUID().uuidString).txt")
        let vocabulary = [
            "fashionable", "lightweight", "plastic", "moulded", "produced", "territory", "individual",
            "liaise", "fantastic", "PowerPoint", "presentation", "website", "electronics", "design",
            "metal", "cheaper", "remote", "controls", "Telewest", "silver", "smarter",
        ].joined(separator: "\n")
        try vocabulary.write(
            to: vocabularyFile, atomically: true, encoding: .utf8,
        )
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = WhisperKitEngine()
        engine.modelVariant = modelVariant
        engine.language = "en"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "WhisperKit model failed to load")

        let baselineSegments = try await engine.transcribeSegments(audioPath: truth.audioURL)
        let baseline = WERCalculator.werBreakdown(
            reference: truth.text,
            hypothesis: baselineSegments.map(\.text).joined(separator: " "),
        )

        engine.customVocabularyPath = vocabularyFile.path
        engine.vocabularyPromptEnabled = true
        let hintedSegments = try await engine.transcribeSegments(audioPath: truth.audioURL)
        let hinted = WERCalculator.werBreakdown(
            reference: truth.text,
            hypothesis: hintedSegments.map(\.text).joined(separator: " "),
        )

        XCTAssertGreaterThan(
            engine.vocabularyPromptTokenCount,
            0,
            "The enabled prompt must reach the real WhisperKit decoder as content tokens",
        )
        XCTAssertLessThanOrEqual(
            engine.vocabularyPromptTokenCount,
            WhisperVocabularyPrompt.defaultTokenBudget,
            "Tokenizer wrapper tokens must not consume the vocabulary prompt budget",
        )

        let baselineTailCoverage = tailCoverage(of: baselineSegments, duration: truth.duration)
        let hintedTailCoverage = tailCoverage(of: hintedSegments, duration: truth.duration)
        print(
            """
            WhisperKit experimental vocabulary prompt measurement (non-gating)
              fixture: \(truth.fixture), model: \(modelVariant)
              content tokens: \(engine.vocabularyPromptTokenCount)/\(WhisperVocabularyPrompt.defaultTokenBudget)
              baseline: WER \(baseline.wer), deletions \(baseline.deletions), tail coverage \(baselineTailCoverage)
              prompted: WER \(hinted.wer), deletions \(hinted.deletions), tail coverage \(hintedTailCoverage)
              delta: WER \(hinted.wer - baseline.wer), deletions \(hinted.deletions - baseline.deletions),
                tail coverage \(hintedTailCoverage - baselineTailCoverage)
            """,
        )
    }

    private func tailCoverage(of segments: [TimestampedSegment], duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let lastEnd = segments.map(\.end).max() ?? 0
        return min(max(lastEnd / duration, 0), 1)
    }

    // Soft threshold of 0.5 catches catastrophic breakage (corrupted model,
    // audio not loaded, biasing prompt destroying decoding) but stays well
    // above the production baseline (~0.23-0.29 with explicit `language=de`).
    private func runFixture(named name: String, language: String = "de") async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = modelVariant
        engine.language = language
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
