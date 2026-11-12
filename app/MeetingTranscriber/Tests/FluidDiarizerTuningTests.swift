import CoreML
import FluidAudio
@testable import MeetingTranscriber
import XCTest

/// Tests the `OfflineDiarizerTuning` struct and its `OfflineDiarizerConfig`
/// projection. These verify defaults track FluidAudio's `community` configs
/// and that the pure builder applies tuning without disturbing other knobs.
final class FluidDiarizerTuningTests: XCTestCase {
    // MARK: - Defaults

    func testTuningStructDefaults() {
        let tuning = OfflineDiarizerTuning.defaults

        // Mirror FluidAudio's Clustering.community + Embedding.community.
        XCTAssertEqual(tuning.clusterThreshold, OfflineDiarizerConfig.Clustering.community.threshold)
        XCTAssertEqual(tuning.warmStartFa, OfflineDiarizerConfig.Clustering.community.warmStartFa)
        XCTAssertEqual(tuning.warmStartFb, OfflineDiarizerConfig.Clustering.community.warmStartFb)
        XCTAssertEqual(
            tuning.minSegmentDurationSeconds,
            OfflineDiarizerConfig.Embedding.community.minSegmentDurationSeconds,
        )
        XCTAssertEqual(tuning.excludeOverlap, OfflineDiarizerConfig.Embedding.community.excludeOverlap)
    }

    // MARK: - apply(to:)

    func testTuningAppliedToOfflineConfig() {
        let tuning = OfflineDiarizerTuning(
            clusterThreshold: 0.5,
            warmStartFa: 0.12,
            warmStartFb: 1.1,
            minSegmentDurationSeconds: 2.0,
            excludeOverlap: false,
        )

        let config = tuning.apply(to: OfflineDiarizerConfig())

        XCTAssertEqual(config.clustering.threshold, 0.5)
        XCTAssertEqual(config.clustering.warmStartFa, 0.12)
        XCTAssertEqual(config.clustering.warmStartFb, 1.1)
        XCTAssertEqual(config.embedding.minSegmentDurationSeconds, 2.0)
        XCTAssertFalse(config.embedding.excludeOverlap)
    }

    func testTuningPreservesUnrelatedKnobs() {
        let tuning = OfflineDiarizerTuning(
            clusterThreshold: 0.42,
            warmStartFa: 0.05,
            warmStartFb: 0.5,
            minSegmentDurationSeconds: 0.5,
            excludeOverlap: true,
        )

        let config = tuning.apply(to: OfflineDiarizerConfig())

        // Segmentation, VBx and post-processing knobs must come from defaults.
        XCTAssertEqual(
            config.segmentation.windowDurationSeconds,
            OfflineDiarizerConfig.Segmentation.community.windowDurationSeconds,
        )
        XCTAssertEqual(config.vbx.maxIterations, OfflineDiarizerConfig.VBx.community.maxIterations)
        XCTAssertEqual(
            config.postProcessing.minGapDurationSeconds,
            OfflineDiarizerConfig.PostProcessing.community.minGapDurationSeconds,
        )
    }

    // MARK: - FluidOfflineProcessor.makeConfig

    func testMakeConfigAppliesTuning() {
        let tuning = OfflineDiarizerTuning(
            clusterThreshold: 0.55,
            warmStartFa: 0.08,
            warmStartFb: 0.9,
            minSegmentDurationSeconds: 1.5,
            excludeOverlap: false,
        )
        let config = FluidOfflineProcessor.makeConfig(tuning: tuning, numSpeakers: nil)

        XCTAssertEqual(config.clustering.threshold, 0.55)
        XCTAssertEqual(config.clustering.warmStartFa, 0.08)
        XCTAssertEqual(config.clustering.warmStartFb, 0.9)
        XCTAssertEqual(config.embedding.minSegmentDurationSeconds, 1.5)
        XCTAssertFalse(config.embedding.excludeOverlap)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
    }

    func testMakeConfigForcesExactSpeakerCount() {
        // Forced exact (numSpeakers), not a cap — see makeConfig for why.
        let config = FluidOfflineProcessor.makeConfig(tuning: .defaults, numSpeakers: 4)

        XCTAssertEqual(config.clustering.numSpeakers, 4)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
    }

    func testMakeConfigIgnoresZeroOrNegativeSpeakerCount() {
        let zero = FluidOfflineProcessor.makeConfig(tuning: .defaults, numSpeakers: 0)
        XCTAssertNil(zero.clustering.minSpeakers)
        XCTAssertNil(zero.clustering.maxSpeakers)

        let negative = FluidOfflineProcessor.makeConfig(tuning: .defaults, numSpeakers: -3)
        XCTAssertNil(negative.clustering.minSpeakers)
        XCTAssertNil(negative.clustering.maxSpeakers)
    }

    func testPreparePassesNonMetalConfigurationToFluidAudio() async throws {
        var receivedComputeUnits: [MLComputeUnits] = []
        var processor = FluidOfflineProcessor { _, configuration in
            receivedComputeUnits.append(configuration.computeUnits)
        }

        try await processor.prepare(numSpeakers: nil)

        XCTAssertEqual(receivedComputeUnits, [.cpuAndNeuralEngine])
    }

    /// The shared WeSpeaker loader (Sortformer / Nemotron 3 embeddings and
    /// the live matcher's first launch) must hand FluidAudio a configuration
    /// carrying the units it was asked for. Without one FluidAudio picks its
    /// own default, `.all` outside CI. `.cpuOnly` is no default anywhere, so
    /// it only arrives if the argument is passed through.
    func testLoadDiarizerModelsPassesRequestedComputeUnitsToFluidAudio() async {
        struct LoadNotAttempted: Error {}
        var receivedComputeUnits: [MLComputeUnits] = []
        do {
            _ = try await FluidOfflineProcessor.loadDiarizerModels(computeUnits: .cpuOnly) { configuration in
                receivedComputeUnits.append(configuration.computeUnits)
                throw LoadNotAttempted()
            }
            XCTFail("the failing load must abort the helper")
        } catch {
            XCTAssertTrue(error is LoadNotAttempted, "unexpected error: \(error)")
        }
        XCTAssertEqual(
            receivedComputeUnits, [.cpuOnly],
            "the helper must pass the requested compute units on to FluidAudio",
        )
    }
}
