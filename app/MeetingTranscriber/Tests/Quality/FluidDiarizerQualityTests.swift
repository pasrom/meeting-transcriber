@testable import MeetingTranscriber
import XCTest

/// Production-model FluidAudio diarization quality tests. Skipped by default
/// — gated by `RUN_QUALITY_TESTS=1` so a normal `swift test` run on a dev
/// machine doesn't pull the diarization models. CI's quality job sets the
/// env var.
///
/// Computes DER per fixture × mode and appends rows to `QualityResultsWriter`.
/// Pairs with `WhisperKitQualityTests` (WER); the writer aggregates both.
@MainActor
final class FluidDiarizerQualityTests: XCTestCase {
    func test_offline_twoSpeakers_de_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "two_speakers_de", mode: .offline)
    }

    func test_offline_threeSpeakers_de_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "three_speakers_de", mode: .offline)
    }

    func test_sortformer_twoSpeakers_de_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "two_speakers_de", mode: .sortformer)
    }

    func test_sortformer_threeSpeakers_de_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "three_speakers_de", mode: .sortformer)
    }

    // MARK: - Helpers

    /// Per-mode soft sanity bound. Set well above current observed baselines so
    /// the test catches catastrophic regressions (model corrupted, audio not
    /// loaded, segments=0) without flapping on small variance.
    ///
    /// Offline mode systematically under-clusters short fixtures (≤30 s) — both
    /// `two_speakers_de` and `three_speakers_de` collapse to 1 speaker, producing
    /// DER ≈0.53 and ≈0.68 respectively as of 2026-05-10. The offline threshold
    /// is set high enough to accept that baseline; it would still trip if the
    /// diarizer regressed to "no segments at all" (DER=1.0). Sortformer is
    /// overlap-aware end-to-end and handles short fixtures fine.
    private static let derThreshold: [DiarizerMode: Double] = [
        .offline: 0.85,
        .sortformer: 0.50,
    ]

    private func runDERFixture(named name: String, mode: DiarizerMode) async throws {
        let truth = try GroundTruth.load(named: name)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: truth.audioURL.path),
            "Audio fixture missing: \(truth.audioURL.path)",
        )

        let diarizer = FluidDiarizer(mode: mode)

        let started = Date()
        let result = try await diarizer.run(
            audioPath: truth.audioURL,
            numSpeakers: nil,
            meetingTitle: name,
        )
        let elapsed = Date().timeIntervalSince(started)

        let hypothesis = result.segments.map { seg in
            DERCalculator.Turn(speaker: seg.speaker, start: seg.start, end: seg.end)
        }
        let breakdown = DERCalculator.derBreakdown(
            reference: truth.diarizationTurns,
            hypothesis: hypothesis,
        )

        QualityResultsWriter.shared.append(
            QualityResult(
                engine: "fluidDiarizer.\(mode.rawValue)",
                fixture: name,
                modelVariant: nil,
                wer: nil,
                der: breakdown.der,
                werBreakdown: nil,
                derBreakdown: .init(breakdown),
                appVersion: qualityAppVersion,
                timestamp: ISO8601DateFormatter().string(from: started),
                durationSeconds: elapsed,
            ),
        )
        _ = try? QualityResultsWriter.shared.flush()

        let threshold = Self.derThreshold[mode, default: 0.5]
        XCTAssertLessThan(
            breakdown.der,
            threshold,
            "DER too high (\(breakdown.der)) for \(name) in \(mode.rawValue) mode — "
                + "hypothesis had \(hypothesis.count) segments across "
                + "\(Set(hypothesis.map(\.speaker)).count) speakers",
        )
    }
}
