@testable import MeetingTranscriber
import XCTest

final class FluidDiarizerSortformerTests: XCTestCase {
    func testDiarizerModeDefault() {
        let settings = AppSettings()
        XCTAssertEqual(settings.diarizerMode, .offline)
    }

    func testDiarizerModeLabels() {
        XCTAssertEqual(DiarizerMode.offline.label, "Offline (Clustering)")
        XCTAssertEqual(DiarizerMode.sortformer.label, "Sortformer (Overlap-aware)")
    }

    func testFluidDiarizerDefaultModeIsOffline() {
        let diarizer = FluidDiarizer()
        XCTAssertEqual(diarizer.mode, .offline)
    }

    func testFluidDiarizerAcceptsSortformerMode() {
        let diarizer = FluidDiarizer(mode: .sortformer)
        XCTAssertEqual(diarizer.mode, .sortformer)
    }

    // MARK: - Phase 1 (issue #165): overlap-exclusion mask builder

    func testBuildOverlapExcludedMasksAllSingleSpeaker() {
        // 4 frames × 2 speakers; speaker 0 active in frames 0+1, speaker 1 active in frames 2+3.
        // Threshold 0.5; no overlaps anywhere → all frames pass through as single-speaker.
        let predictions: [Float] = [
            0.9, 0.1, // frame 0 — speaker 0 only
            0.8, 0.2, // frame 1 — speaker 0 only
            0.1, 0.9, // frame 2 — speaker 1 only
            0.3, 0.7, // frame 3 — speaker 1 only
        ]
        let masks = FluidDiarizer.buildOverlapExcludedMasks(
            predictions: predictions, numSpeakers: 2, threshold: 0.5,
        )
        XCTAssertEqual(masks, [
            [1.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 1.0],
        ])
    }

    func testBuildOverlapExcludedMasksZeroesOverlapFrame() {
        // Frame 0 has speakers 0 + 1 both above threshold → must be zeroed across BOTH.
        // Frame 1 has only speaker 0 active → speaker 0's mask is 1.0 there.
        let predictions: [Float] = [
            0.9, 0.9, // frame 0 — overlap
            0.9, 0.1, // frame 1 — speaker 0 only
        ]
        let masks = FluidDiarizer.buildOverlapExcludedMasks(
            predictions: predictions, numSpeakers: 2, threshold: 0.5,
        )
        XCTAssertEqual(masks[0], [0.0, 1.0])
        XCTAssertEqual(masks[1], [0.0, 0.0])
    }

    func testBuildOverlapExcludedMasksSilentFrameProducesNoMask() {
        // All speakers below threshold → frame is "silence", no speaker's mask set.
        let predictions: [Float] = [
            0.3, 0.2, // both below 0.5
            0.9, 0.1,
        ]
        let masks = FluidDiarizer.buildOverlapExcludedMasks(
            predictions: predictions, numSpeakers: 2, threshold: 0.5,
        )
        XCTAssertEqual(masks[0], [0.0, 1.0])
        XCTAssertEqual(masks[1], [0.0, 0.0])
    }

    func testBuildOverlapExcludedMasksThreeSpeakerOverlapAllZeroed() {
        // All 3 speakers above threshold in same frame → triple overlap, all zeroed.
        let predictions: [Float] = [0.9, 0.8, 0.7]
        let masks = FluidDiarizer.buildOverlapExcludedMasks(
            predictions: predictions, numSpeakers: 3, threshold: 0.5,
        )
        XCTAssertEqual(masks, [[0.0], [0.0], [0.0]])
    }

    func testResampleMaskUpsamplesPreservingActivePattern() {
        // 4 frames → 8 frames via nearest-neighbour: each src frame maps to
        // two adjacent target frames.
        let src: [Float] = [1, 0, 1, 0]
        let out = FluidDiarizer.resampleMask(src, to: 8)
        XCTAssertEqual(out, [1, 1, 0, 0, 1, 1, 0, 0])
    }

    func testResampleMaskDownsamplesByStriding() {
        // 8 → 4: every other frame survives.
        let src: [Float] = [1, 1, 0, 0, 1, 1, 0, 0]
        let out = FluidDiarizer.resampleMask(src, to: 4)
        XCTAssertEqual(out, [1, 0, 1, 0])
    }

    func testResampleMaskHandlesPyannoteRatio() {
        // Production case: 125-frame Sortformer mask → 589-frame WeSpeaker mask.
        // Ones at positions 0..62 → out should be ones from 0..295 roughly.
        var src = [Float](repeating: 0.0, count: 125)
        for i in 0 ..< 63 {
            src[i] = 1.0
        } // first half active
        let out = FluidDiarizer.resampleMask(src, to: 589)
        XCTAssertEqual(out.count, 589)
        // First and last should reflect original pattern at the boundaries.
        XCTAssertEqual(out[0], 1.0)
        XCTAssertEqual(out[588], 0.0)
        // The transition occurs roughly at out[i] where i*125/589 == 63, i.e. i ≈ 297.
        XCTAssertEqual(out[296], 1.0, "frame 296 maps to src 62 (active)")
        XCTAssertEqual(out[297], 0.0, "frame 297 maps to src 63 (silence)")
    }

    func testResampleMaskEmptyInputProducesZeros() {
        let out = FluidDiarizer.resampleMask([], to: 100)
        XCTAssertEqual(out, [Float](repeating: 0.0, count: 100))
    }

    func testAggregateCentroidsL2NormalisesMean() {
        // Two chunks for speaker A: [1,0,0,0] + [0,1,0,0] = mean [0.5, 0.5, 0, 0]
        // L2-normalised: [√0.5, √0.5, 0, 0] ≈ [0.707, 0.707, 0, 0]
        let sums: [String: [Float]] = ["A": [1, 1, 0, 0]]
        let counts = ["A": 2]
        let result = FluidDiarizer.aggregateCentroids(sums: sums, counts: counts)
        XCTAssertEqual(result["A"]?.count, 4)
        XCTAssertEqual(result["A"]?[0] ?? 0, sqrt(0.5), accuracy: 1e-6)
        XCTAssertEqual(result["A"]?[1] ?? 0, sqrt(0.5), accuracy: 1e-6)
        XCTAssertEqual(result["A"]?[2] ?? 0, 0, accuracy: 1e-6)
        // Resulting vector must be unit-norm
        let norm = result["A"]?.reduce(0) { $0 + $1 * $1 } ?? 0
        XCTAssertEqual(Double(norm), 1.0, accuracy: 1e-6)
    }

    func testAggregateCentroidsZeroVectorStaysZero() {
        // Sum is all-zero → norm 0 → guard returns the zero vector unchanged.
        // Prevents `0 / 0 = NaN` corrupting the centroid.
        let result = FluidDiarizer.aggregateCentroids(
            sums: ["S": [0, 0, 0]],
            counts: ["S": 5],
        )
        XCTAssertEqual(result["S"], [0, 0, 0])
    }

    func testAggregateCentroidsHandlesMultipleSpeakers() {
        let result = FluidDiarizer.aggregateCentroids(
            sums: ["A": [3, 4, 0], "B": [0, 0, 5]],
            counts: ["A": 1, "B": 1],
        )
        // A: [3, 4, 0] → L2-normalised = [0.6, 0.8, 0] (3-4-5 triangle)
        XCTAssertEqual(result["A"]?[0] ?? 0, 0.6, accuracy: 1e-6)
        XCTAssertEqual(result["A"]?[1] ?? 0, 0.8, accuracy: 1e-6)
        XCTAssertEqual(result["A"]?[2] ?? 0, 0, accuracy: 1e-6)
        // B: [0, 0, 5] → L2-normalised = [0, 0, 1]
        XCTAssertEqual(result["B"]?[0] ?? 0, 0, accuracy: 1e-6)
        XCTAssertEqual(result["B"]?[2] ?? 0, 1.0, accuracy: 1e-6)
    }

    func testAggregateCentroidsMissingCountDefaultsToOne() {
        // Speaker in sums but absent from counts → treat as count=1 (don't divide
        // the sum away). Defensive guard against accidental input mismatch.
        let result = FluidDiarizer.aggregateCentroids(
            sums: ["X": [3, 4, 0]],
            counts: [:],
        )
        // Same as count=1 → [3, 4, 0] L2-normalised to [0.6, 0.8, 0]
        XCTAssertEqual(result["X"]?[0] ?? 0, 0.6, accuracy: 1e-6)
        XCTAssertEqual(result["X"]?[1] ?? 0, 0.8, accuracy: 1e-6)
    }

    func testBuildOverlapExcludedMasksEmptyInputs() {
        XCTAssertEqual(
            FluidDiarizer.buildOverlapExcludedMasks(predictions: [], numSpeakers: 4, threshold: 0.5),
            [],
        )
        XCTAssertEqual(
            FluidDiarizer.buildOverlapExcludedMasks(predictions: [0.9, 0.1], numSpeakers: 0, threshold: 0.5),
            [],
        )
    }
}
