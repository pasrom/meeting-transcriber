import CoreML
import FluidAudio
@testable import MeetingTranscriber
import XCTest

final class FluidDiarizerSortformerTests: XCTestCase {
    func testDiarizerModeDefault() throws {
        // Its own suite: on `.standard` this reads whatever another run left in
        // the test host's real domain, which is not the default.
        let suite = "FluidDiarizerSortformerTests-\(getpid())-\(UUID().uuidString)"
        defer { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)))
        XCTAssertEqual(settings.diarizerMode, .offline)
    }

    func testDiarizerModeLabels() {
        XCTAssertEqual(DiarizerMode.offline.label, "Offline (Clustering)")
        XCTAssertEqual(DiarizerMode.sortformer.label, "Sortformer (Overlap-aware)")
        XCTAssertEqual(DiarizerMode.nemotron.label, "Nemotron 3 (8 speakers)")
    }

    func testFluidDiarizerDefaultModeIsOffline() {
        let diarizer = FluidDiarizer()
        XCTAssertEqual(diarizer.mode, .offline)
    }

    func testFluidDiarizerAcceptsSortformerMode() {
        let diarizer = FluidDiarizer(mode: .sortformer)
        XCTAssertEqual(diarizer.mode, .sortformer)
    }

    /// The Sortformer load must ask FluidAudio for CPU + Neural Engine
    /// explicitly. Passing nothing lets FluidAudio pick `.all` for the default
    /// config, which was measurably slower. The stub hands back a diarizer
    /// with no model in it, so nothing is downloaded or compiled and the run
    /// fails at the audio, after the load this test is about.
    func testSortformerLoadRequestsCpuAndNeuralEngine() async {
        var requested: [MLComputeUnits] = []
        let diarizer = FluidDiarizer(mode: .sortformer) { computeUnits in
            requested.append(computeUnits)
            return (SortformerDiarizer(), computeUnits)
        }

        for _ in 0 ..< 2 {
            do {
                _ = try await diarizer.run(
                    audioPath: URL(fileURLWithPath: "/nonexistent/never-read.wav"),
                    numSpeakers: nil,
                    meetingTitle: "compute-units",
                )
                XCTFail("The stub diarizer has no model, so run must throw")
            } catch {
                // Expected: the audio does not exist and no model is loaded.
            }
        }

        XCTAssertEqual(requested, [.cpuAndNeuralEngine], "Asked once, and for CPU + Neural Engine; the second run reuses the diarizer")
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

    // MARK: - Post-hoc embedding window geometry

    // WeSpeaker sees a 10 s window as 589 frames; frame j starts at sample
    // floor(j * 160 000 / 589). A short chunk's audio is loop-padded to the
    // window, so frame j reads the audio (and the mask) at that sample
    // modulo the chunk length. Sortformer frames are 1280 samples (80 ms):
    // a 2 s tail (32 000 samples) is covered by WeSpeaker frames 0...117
    // (117 -> 31 782, 118 -> 32 054), and in that span frame j reads
    // Sortformer frame floor(j * 125 / 589). The expected numbers below
    // are worked out by hand from that, not from the helpers.

    private static func mask(count: Int, active: Range<Int>) -> [Float] {
        (0 ..< count).map { active.contains($0) ? 1 : 0 }
    }

    func testWindowMaskFullChunkKeepsTheWholeWindow() {
        // Full 10 s: 125 -> 589; src 62/63 boundary between targets 296/297.
        let sortformer = FluidDiarizer.weSpeakerWindowMask(
            Self.mask(count: 125, active: 0 ..< 63),
            samplesPerMaskFrame: 1280, chunkSampleCount: 160_000, frameCount: 589,
        )
        XCTAssertEqual(sortformer.count, 589)
        XCTAssertEqual(sortformer.reduce(0, +), 297)
        XCTAssertEqual(sortformer[296], 1)
        XCTAssertEqual(sortformer[297], 0)
        // Nemotron 3: 1000 frames of 160 samples; j * 1000 / 589 < 500 up to j = 294.
        let nemotron = FluidDiarizer.weSpeakerWindowMask(
            Self.mask(count: 1000, active: 0 ..< 500),
            samplesPerMaskFrame: 160, chunkSampleCount: 160_000, frameCount: 589,
        )
        XCTAssertEqual(nemotron.reduce(0, +), 295)
        XCTAssertEqual(nemotron[294], 1)
        XCTAssertEqual(nemotron[295], 0)
    }

    func testWindowMaskTailFollowsTheLoopedAudio() {
        // Speaker active in the tail's second half only (frames 13...24,
        // 1.04 s to 2.0 s). Target 61 reads src 12, target 62 reads src 13.
        let out = FluidDiarizer.weSpeakerWindowMask(
            Self.mask(count: 25, active: 13 ..< 25),
            samplesPerMaskFrame: 1280, chunkSampleCount: 32000, frameCount: 589,
        )
        XCTAssertEqual(out.count, 589, "the model input shape stays [3, 589]")
        // Masks are 0/1, so a range sum counts its active frames.
        XCTAssertEqual(out[0 ..< 62].reduce(0, +), 0)
        XCTAssertEqual(out[62 ..< 118].reduce(0, +), 56, "activity must sit under the tail's own audio")
        // In the padding the mask repeats with the audio: 118 -> sample
        // 32 054 = 54 into the loop (src 0); 180 -> 48 896 = 16 896 (src 13);
        // 235 -> 63 837 = 31 837 (src 24); 236 -> 64 108 = 108 (src 0).
        XCTAssertEqual(out[118], 0)
        XCTAssertEqual(out[180], 1)
        XCTAssertEqual(out[235], 1)
        XCTAssertEqual(out[236], 0)
    }

    func testWindowMaskClampsToAMaskShorterThanTheAudio() {
        // The diarizer's frame count need not match the audio length. With
        // 24 tail frames for 2 s of audio, targets reading src 24 (j >= 114)
        // have no mask frame and stay zero: ones at 62...113.
        let out = FluidDiarizer.weSpeakerWindowMask(
            Self.mask(count: 24, active: 13 ..< 24),
            samplesPerMaskFrame: 1280, chunkSampleCount: 32000, frameCount: 589,
        )
        XCTAssertEqual(out[0 ..< 118].reduce(0, +), 52)
        XCTAssertEqual(out[113], 1)
        XCTAssertEqual(out[114], 0)
    }

    func testWindowMaskLoopsAtTheLastAudioSample() {
        // A 32 600-sample tail spans 26 frames, the last (25) only partly.
        // Targets 118...120 start on samples 32 054, 32 325, 32 597, inside
        // frame 25; target 121 starts on 32 869, which loops to 269 (src 0),
        // not into the part of frame 25 past the audio.
        let out = FluidDiarizer.weSpeakerWindowMask(
            Self.mask(count: 26, active: 25 ..< 26),
            samplesPerMaskFrame: 1280, chunkSampleCount: 32600, frameCount: 589,
        )
        XCTAssertEqual(out[117], 0)
        XCTAssertEqual(out[118 ..< 121].reduce(0, +), 3)
        XCTAssertEqual(out[121], 0)
    }

    func testWindowLoopPadsTheChunkAudio() {
        let window = FluidDiarizer.weSpeakerWindow([9, 8, 7, 6, 5], range: 2 ..< 5)
        XCTAssertEqual(window.count, 160_000)
        XCTAssertEqual(Array(window[0 ..< 6]), [7, 6, 5, 7, 6, 5])
        XCTAssertEqual(window[159_999], 7, "159 999 = 3 * 53 333, back at the chunk's first sample")
    }

    // 12 s clip, 150 Sortformer frames: one full chunk, then a 2 s tail
    // (frames 125...149, tail frames 0...24).
    private static func planTwelveSeconds(_ masks: [[Float]]) -> [FluidDiarizer.EmbeddingChunkPlan] {
        FluidDiarizer.planEmbeddingChunks(
            audioSampleCount: 192_000, masks: masks, samplesPerMaskFrame: 1280, weSpeakerFrameCount: 589,
        )
    }

    func testPlanTwelveSecondClipEmbedsTheTailFromItsOwnActivity() throws {
        // Speaker 1 talks in the first 5 s, speaker 0 only in the last
        // second (frames 138...149, tail frames 13...24). This pins what the
        // call site hands the extractor: a mask stretched over the whole
        // window put no activity under the tail's audio for speaker 0.
        let plans = Self.planTwelveSeconds([
            Self.mask(count: 150, active: 138 ..< 150),
            Self.mask(count: 150, active: 0 ..< 63),
        ])
        XCTAssertEqual(plans.map(\.sampleRange), [0 ..< 160_000, 160_000 ..< 192_000])
        guard plans.count == 2 else { return }
        XCTAssertEqual(plans[0].slots, [1])
        XCTAssertEqual(plans[0].masks.first?.reduce(0, +), 297)
        XCTAssertEqual(plans[1].slots, [0])
        let tail = try XCTUnwrap(plans[1].masks.first)
        XCTAssertEqual(tail.count, 589)
        XCTAssertEqual(tail[0 ..< 118].reduce(0, +), 56)
        XCTAssertEqual(tail[62 ..< 118].reduce(0, +), 56)
    }

    func testPlanGatesTailSlotsOnActivityInsideTheAudio() {
        // In the tail, speaker 0 has one 80 ms frame (WeSpeaker targets
        // 0...4, five frames) and speaker 1 three frames (targets 0...14,
        // fifteen). The bar is ten frames inside the audio. Counted over
        // the loop-padded window, or over a stretched mask (24 frames), the
        // blip would pass.
        let plans = Self.planTwelveSeconds([
            Self.mask(count: 150, active: 125 ..< 126),
            Self.mask(count: 150, active: 0 ..< 63).enumerated().map { $0 >= 125 && $0 < 128 ? 1 : $1 },
        ])
        XCTAssertEqual(plans.map(\.slots), [[1], [1]])
    }

    func testPlanSkipsAChunkWithNoSlotActiveEnough() {
        let plans = Self.planTwelveSeconds([Self.mask(count: 150, active: 0 ..< 63)])
        XCTAssertEqual(plans.map(\.sampleRange), [0 ..< 160_000])
    }

    func testPlanSkipsATailShorterThanOneDiarizerFrame() {
        // 100 samples past 10 s are less than one 1280-sample frame, and
        // only one WeSpeaker frame: below the activity bar, so no model call.
        let plans = FluidDiarizer.planEmbeddingChunks(
            audioSampleCount: 160_100,
            masks: [Self.mask(count: 126, active: 0 ..< 126)],
            samplesPerMaskFrame: 1280,
            weSpeakerFrameCount: 589,
        )
        XCTAssertEqual(plans.map(\.sampleRange), [0 ..< 160_000])
    }

    func testPlanStopsWhereTheMaskEnds() {
        // Audio runs 14 s past the last mask frame: no chunk without a
        // mask, and no slice starting past the mask's end.
        let plans = FluidDiarizer.planEmbeddingChunks(
            audioSampleCount: 384_000,
            masks: [Self.mask(count: 125, active: 0 ..< 125)],
            samplesPerMaskFrame: 1280,
            weSpeakerFrameCount: 589,
        )
        XCTAssertEqual(plans.count, 1)
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
