@testable import MeetingTranscriber
import XCTest

/// End-to-end coverage for Phase 1 of issue #165: Sortformer mode must
/// now populate `DiarizationResult.embeddings` via post-hoc WeSpeaker
/// extraction on overlap-excluded frames. Before this PR the field was
/// nil in Sortformer mode and `PipelineQueue.processNext()`'s naming-flow
/// `guard let embeddings else { break }` aborted (issue #109).
///
/// Acceptance principle (matches the channel-health E2E pattern from
/// `feedback_e2e_must_exercise_production_chain`): revert the
/// `extractSortformerEmbeddings` call in `FluidDiarizer.runSortformer`
/// and these tests must fail.
///
/// Gated via `RUN_QUALITY_TESTS=1` because the first run pulls the
/// `pyannote_segmentation` + `wespeaker_v2` CoreML models (~150 MB).
/// Subsequent runs are model-cached and complete in ~5 s on M-series.
@MainActor
final class SortformerEmbeddingsE2ETests: XCTestCase {
    func testSortformerProducesPerSpeakerEmbeddingsAfterPhase1() async throws {
        try skipUnlessQualityRun()

        let truth = try GroundTruth.load(named: "two_speakers_de")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: truth.audioURL.path),
            "Audio fixture missing: \(truth.audioURL.path)",
        )

        let diarizer = FluidDiarizer(mode: .sortformer)
        let result = try await diarizer.run(
            audioPath: truth.audioURL, numSpeakers: nil, meetingTitle: "two_speakers_de",
        )

        // (1) Phase 1's contract: embeddings must be populated so the naming
        // dialog branch in PipelineQueue lights up (closes #109).
        let embeddings = try XCTUnwrap(
            result.embeddings,
            "Sortformer mode must populate result.embeddings post-Phase 1 (issue #165) — was nil",
        )

        // (2) Fixture has two speakers, expect at least 2 active speaker slots.
        XCTAssertGreaterThanOrEqual(
            embeddings.count, 2,
            "Expected ≥2 active speakers from two_speakers_de fixture, got \(embeddings.count)",
        )

        // (3) Each embedding is L2-normalised 256-d (WeSpeaker output shape).
        for (label, emb) in embeddings {
            XCTAssertEqual(emb.count, 256, "Speaker \(label) has wrong embedding dim")
            let norm = (emb.reduce(into: Float(0)) { $0 += $1 * $1 }).squareRoot()
            XCTAssertEqual(
                Double(norm), 1.0, accuracy: 1e-3,
                "Speaker \(label) embedding is not L2-normalised (norm=\(norm))",
            )
        }

        // (4) Different speakers must produce embeddings that are at least
        // weakly distinct — cosine distance above the SpeakerMatcher matching
        // threshold (0.40) for ANY pair. If all pairs collapse below 0.40 the
        // post-hoc extraction has produced near-duplicate centroids, which
        // would break `SpeakerMatcher.match` (every new speaker would match
        // every prior speaker).
        let labels = Array(embeddings.keys)
        var sawDistinctPair = false
        for i in 0 ..< labels.count {
            for j in (i + 1) ..< labels.count {
                let a = embeddings[labels[i]] ?? []
                let b = embeddings[labels[j]] ?? []
                let dot = zip(a, b).reduce(into: Float(0)) { $0 += $1.0 * $1.1 }
                let distance = 1.0 - dot
                if distance > 0.40 { sawDistinctPair = true }
            }
        }
        XCTAssertTrue(
            sawDistinctPair,
            "All Sortformer post-hoc speaker embeddings collapse below the SpeakerMatcher threshold (0.40) "
                + "— extraction not differentiating speakers",
        )
    }
}
