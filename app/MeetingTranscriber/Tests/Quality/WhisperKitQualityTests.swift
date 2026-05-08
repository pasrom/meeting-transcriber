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
        try requireQualityRun()
        try await runWERFixture(named: "two_speakers_de")
    }

    func test_whisperKit_threeSpeakers_de_wer() async throws {
        try requireQualityRun()
        try await runWERFixture(named: "three_speakers_de")
    }

    // MARK: - Helpers

    private func runWERFixture(named name: String) async throws {
        let truth = try GroundTruth.load(named: name)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: truth.audioURL.path),
            "Audio fixture missing: \(truth.audioURL.path)",
        )

        let engine = WhisperKitEngine()
        engine.modelVariant = modelVariant
        engine.language = "de"

        let started = Date()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "WhisperKit model failed to load")

        let segments = try await engine.transcribeSegments(audioPath: truth.audioURL)
        let hypothesis = segments.map(\.text).joined(separator: " ")
        let breakdown = WERCalculator.werBreakdown(
            reference: truth.text,
            hypothesis: hypothesis,
        )

        let elapsed = Date().timeIntervalSince(started)
        QualityResultsWriter.shared.append(
            QualityResult(
                engine: "whisperKit",
                fixture: name,
                modelVariant: modelVariant,
                wer: breakdown.wer,
                der: nil,
                werBreakdown: .init(breakdown),
                derBreakdown: nil,
                appVersion: appVersion,
                timestamp: ISO8601DateFormatter().string(from: started),
                durationSeconds: elapsed,
            ),
        )

        // Soft sanity bound — the production model on clean German audio
        // should be well under 30 % WER on these fixtures. This is not a
        // strict pass/fail threshold, just an early warning that something
        // is catastrophically broken (e.g. model download corrupted, audio
        // not loaded, biasing prompt destroying decoding).
        XCTAssertLessThan(
            breakdown.wer,
            0.5,
            "WER too high: \(breakdown.wer) — hypothesis was: \(hypothesis)",
        )

        // Flush eagerly so even a later test crash doesn't lose this row.
        _ = try? QualityResultsWriter.shared.flush()
    }

    private func requireQualityRun() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_QUALITY_TESTS"] == "1",
            "Set RUN_QUALITY_TESTS=1 to run quality regression tests",
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }
}
