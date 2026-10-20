import FluidAudio
@testable import MeetingTranscriber
import XCTest

/// Pure parts of the Nemotron 3 diarization mode. The model-bound glue in
/// `FluidDiarizer+Nemotron.swift` runs only under `RUN_QUALITY_TESTS=1`
/// (`FluidDiarizerQualityTests`, `SortformerEmbeddingsE2ETests`).
final class FluidDiarizerNemotronTests: XCTestCase {
    func testFluidDiarizerAcceptsNemotronMode() {
        XCTAssertEqual(FluidDiarizer(mode: .nemotron).mode, .nemotron)
    }

    /// Here rather than in `AppSettingsTests`, which sits at the
    /// `file_length` limit.
    func testDiarizerModePersistsNemotron() throws {
        let suiteName = "nemotron-diarizer-mode-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        AppSettings(defaults: defaults).diarizerMode = .nemotron
        XCTAssertEqual(defaults.string(forKey: "diarizerMode"), "nemotron")
        XCTAssertEqual(AppSettings(defaults: defaults).diarizerMode, .nemotron)
    }

    func testNemotronShortLabels() {
        XCTAssertEqual(DiarizerMode.offline.shortLabel, "Offline")
        XCTAssertEqual(DiarizerMode.sortformer.shortLabel, "Sortformer")
        XCTAssertEqual(DiarizerMode.nemotron.shortLabel, "Nemotron 3")
    }

    /// The UI cap and the model's output slots must agree: a Stepper that
    /// offered more speakers than the checkpoint has slots would promise a
    /// count the model can never produce.
    func testNemotronSpeakerCapMatchesModelSlots() {
        XCTAssertEqual(DiarizerMode.nemotron.speakerCap, FluidDiarizer.nemotronConfig.numSpeakers)
        XCTAssertEqual(FluidDiarizer.nemotronTimelineConfig.numSpeakers, FluidDiarizer.nemotronConfig.numSpeakers)
    }

    /// Pins the preset so a change to it is a deliberate one: it decides the
    /// download (one ~200 MB bundle per preset) and the accuracy trade-off.
    func testNemotronUsesFast128Preset() {
        let config = FluidDiarizer.nemotronConfig
        XCTAssertEqual(config.modelFileName, "Nemotron3Diarizer_fast128.mlmodelc")
        XCTAssertEqual(config.chunkLen, 128)
        XCTAssertFalse(config.splitGraph)
    }

    func testNemotronTimelineConfigMatchesModelFrames() {
        let config = FluidDiarizer.nemotronTimelineConfig
        XCTAssertEqual(config.frameDurationSeconds, 0.01, accuracy: 1e-6)
        XCTAssertEqual(config.onsetThreshold, 0.5)
        XCTAssertEqual(config.offsetThreshold, 0.5)
        XCTAssertEqual(config.minFramesOn, 20, "speech shorter than 0.2 s is dropped")
        XCTAssertEqual(config.minFramesOff, 0)
    }

    /// Timeline → segments at Nemotron 3's frame rate: labels are the speaker
    /// slot (the key the post-hoc embeddings use), times come from the 10 ms
    /// grid, and a blip below the 0.2 s floor does not become a segment.
    func testSegmentsFromNemotronTimeline() throws {
        let speakers = FluidDiarizer.nemotronConfig.numSpeakers
        let frames = 400 // 4 s
        var predictions = [Float](repeating: 0, count: frames * speakers)
        func activate(slot: Int, _ range: Range<Int>) {
            for frame in range {
                predictions[frame * speakers + slot] = 0.9
            }
        }
        activate(slot: 0, 0 ..< 150) // 0.0 – 1.5 s
        activate(slot: 3, 160 ..< 170) // 0.1 s blip, below the floor
        activate(slot: 7, 200 ..< 400) // 2.0 – 4.0 s

        let timeline = try DiarizerTimeline(
            allPredictions: predictions, config: FluidDiarizer.nemotronTimelineConfig,
        )
        let segments = FluidDiarizer.segments(from: timeline).sorted { $0.start < $1.start }

        XCTAssertEqual(segments.map(\.speaker), ["SPEAKER_0", "SPEAKER_7"])
        XCTAssertEqual(segments[0].start, 0, accuracy: 1e-3)
        XCTAssertEqual(segments[0].end, 1.5, accuracy: 1e-3)
        XCTAssertEqual(segments[1].start, 2.0, accuracy: 1e-3)
        XCTAssertEqual(segments[1].end, 4.0, accuracy: 1e-3)
    }
}
