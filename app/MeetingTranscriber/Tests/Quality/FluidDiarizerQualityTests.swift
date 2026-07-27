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
    // Synthetic fixtures. Offline systematically under-clusters clips this
    // short (≤30 s): both collapse to a single speaker, giving DER ≈0.53 and
    // ≈0.68 as of 2026-05-10. The 0.85 bound accepts that while still tripping
    // on "no segments at all" (DER 1.0). Sortformer handles short clips fine.
    func test_offline_twoSpeakers_de_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "two_speakers_de", mode: .offline, threshold: 0.85)
    }

    func test_offline_threeSpeakers_de_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "three_speakers_de", mode: .offline, threshold: 0.85)
    }

    func test_sortformer_twoSpeakers_de_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "two_speakers_de", mode: .sortformer, threshold: 0.50)
    }

    func test_sortformer_threeSpeakers_de_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "three_speakers_de", mode: .sortformer, threshold: 0.50)
    }

    // Real recorded meeting: four speakers, ~31 % of the excerpt overlapping,
    // sitting exactly on Sortformer's four-speaker cap. The only fixture whose
    // REFERENCE contains simultaneous speech, so the only one that can charge a
    // diarizer for failing to report it.
    //
    // The synthetic bounds do not transfer. Offline scores far better here
    // (0.36) than on the short synthetic clips (0.53/0.68), which it only fails
    // because they are too short for it to cluster, so reusing 0.85 would leave
    // it effectively ungated.
    //
    // Worth recording: under the overlap-aware metric Sortformer (0.33) beats
    // offline (0.36) here. Under the collapsing metric it looked like the
    // reverse, 0.26 against 0.15, because credit for reporting a second
    // simultaneous speaker was being scored as confusion.
    func test_offline_fourSpeakers_en_real_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "four_speakers_en_ami", mode: .offline, threshold: 0.55)
    }

    func test_sortformer_fourSpeakers_en_real_der() async throws {
        try skipUnlessQualityRun()
        try await runDERFixture(named: "four_speakers_en_ami", mode: .sortformer, threshold: 0.50)
    }

    // MARK: - Helpers

    /// Each test method already names exactly one (fixture, mode) pair, so the
    /// call sites ARE the threshold table and the bound sits next to the
    /// rationale for it. An earlier per-mode dictionary implied the bound was a
    /// property of the mode; it never was. `.offline: 0.85` existed because the
    /// synthetic clips are too SHORT for it to cluster, which is a property of
    /// the fixture.
    private func runDERFixture(
        named name: String,
        mode: DiarizerMode,
        threshold: Double,
    ) async throws {
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

        XCTAssertLessThan(
            breakdown.der,
            threshold,
            "DER too high (\(breakdown.der)) for \(name) in \(mode.rawValue) mode — "
                + "hypothesis had \(hypothesis.count) segments across "
                + "\(Set(hypothesis.map(\.speaker)).count) speakers",
        )
    }
}
