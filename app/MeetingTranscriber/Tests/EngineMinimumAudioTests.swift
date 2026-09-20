@testable import MeetingTranscriber
import XCTest

/// The shortest input an engine will accept, which the pipeline asks for before
/// handing a track over.
///
/// It lives on the engine rather than in the pipeline because it is not one
/// number. FluidAudio refuses anything under 300 ms and says so; WhisperKit has
/// no such floor and pads into its own windows. A pipeline-wide 300 ms would
/// drop a quarter-second track under WhisperKit and annotate the transcript
/// "the microphone track was empty", which would be false, and would tell the
/// protocol model a side of the conversation is missing when it is not.
@MainActor
final class EngineMinimumAudioTests: XCTestCase {
    /// A stand-in for any backend that has published no floor of its own.
    private final class FloorlessEngine: TranscribingEngine {
        var modelState: EngineModelState = .loaded
        var downloadProgress: Double = 1
        var transcriptionProgress: Double = 1
        func loadModel() {}
        func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
            []
        }
    }

    func testAnEngineWithNoFloorOfItsOwnStillRejectsATrackWithNoFrames() {
        XCTAssertEqual(
            FloorlessEngine().minimumAudioFrames, 1,
            "the only floor true for every backend: no frames means nothing to transcribe",
        )
    }

    func testParakeetPublishesTheFloorItActuallyEnforces() {
        XCTAssertEqual(
            ParakeetEngine().minimumAudioFrames, 4800,
            "300 ms at 16 kHz, the threshold FluidAudio throws below",
        )
    }

    /// Measured in the pinned dependency, not assumed: `windowClipTime`
    /// defaults to 1.0 s and WhisperKit's decode loop runs
    /// `while seek < seekClipEnd - windowClipTime * sampleRate`, so a track of
    /// 16000 frames or fewer never enters it and returns no segments at all,
    /// without throwing. At the protocol default of one frame a half-second
    /// utterance would vanish with nothing said about it.
    func testWhisperKitPublishesItsOneSecondFloor() {
        XCTAssertEqual(WhisperKitEngine().minimumAudioFrames, 16001)
    }

    /// The point of the whole arrangement: the same recording is judged by the
    /// engine that will transcribe it, not by a constant the pipeline picked.
    func testAShortButRealTrackSurvivesUnderAnEngineWithNoFloor() {
        let shortTrack = 4000 // a quarter second at 16 kHz
        XCTAssertEqual(
            DualTrackViability.resolve(
                appFrames: 160_000, micFrames: shortTrack,
                minimumFrames: FloorlessEngine().minimumAudioFrames,
            ),
            .both,
        )
        XCTAssertEqual(
            DualTrackViability.resolve(
                appFrames: 160_000, micFrames: shortTrack,
                minimumFrames: ParakeetEngine().minimumAudioFrames,
            ),
            .appOnly,
        )
    }
}
