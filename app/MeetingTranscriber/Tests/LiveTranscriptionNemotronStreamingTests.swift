import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Behaviour pins for the Nemotron streaming path on `LiveTranscriptionController`
/// — any explicitly-configured non-English language routes per-channel captions
/// through `NemotronStreamingCaptionSession` instead of the VAD + re-transcribe
/// `StreamingTranscriber`, with a non-fatal model-load fallback.
///
/// The real model is a multi-hundred-MB CoreML download, so the Nemotron pipeline
/// factory is injected (mirroring the EOU `eouSessionFactory`) and the tests
/// assert on the seams: the factory's call count and the engine's `loadModel`
/// activity. The streaming path never touches the engine; the re-transcribe
/// fallback loads it — those two signatures distinguish which strategy resolved.
@MainActor
final class LiveTranscriptionNemotronStreamingTests: XCTestCase {
    private struct LoadFailure: Error {}

    /// Counts factory invocations; returns two no-op pipelines, or throws.
    @MainActor
    private final class NemotronFactoryProbe {
        private(set) var buildCount = 0
        private let loadError: (any Error)?

        init(loadError: (any Error)? = nil) {
            self.loadError = loadError
        }

        func factory() -> LiveTranscriptionController.NemotronPipelineFactory {
            { _, _, _ in
                self.buildCount += 1
                if let loadError = self.loadError { throw loadError }
                return (NoopPipeline(), NoopPipeline())
            }
        }
    }

    private actor NoopPipeline: LiveCaptionPipeline {
        // swiftlint:disable:next async_without_await
        func ingest(_: LiveAudioBuffer) async {}
        // swiftlint:disable:next async_without_await
        func flush() async {}
    }

    /// Tracks whether the engine's `loadModel()` ran — the tell that the
    /// re-transcribe path was built (the streaming path skips it).
    private final class LoadTrackingEngine: StreamingTranscribingEngine {
        var modelState: EngineModelState = .loaded
        var downloadProgress: Double = 1.0
        var transcriptionProgress: Double = 1.0
        private(set) var loadModelCount = 0

        func loadModel() {
            loadModelCount += 1
        }

        func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
            []
        }

        func transcribeSamples(_: [Float]) -> String {
            ""
        }
    }

    private func makeController(
        probe: NemotronFactoryProbe,
        engine: LoadTrackingEngine,
        captions: LiveCaptionsState = LiveCaptionsState(),
    ) -> LiveTranscriptionController {
        LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "de",
            nemotronPipelineFactory: probe.factory(),
        )
    }

    func testNemotronLanguageBuildsStreamingSessionsWithoutLoadingEngine() async {
        let probe = NemotronFactoryProbe()
        let engine = LoadTrackingEngine()
        let captions = LiveCaptionsState()
        let controller = makeController(probe: probe, engine: engine, captions: captions)

        await controller.prepare()

        XCTAssertEqual(probe.buildCount, 1, "the Nemotron path builds both channels in one factory call")
        XCTAssertEqual(
            engine.loadModelCount, 0,
            "the engine-independent Nemotron path must NOT load the active engine",
        )
        XCTAssertEqual(captions.activeBackend, "Nemotron · DE", "the resolved backend is published for the overlay")
    }

    func testNemotronLoadFailureFallsBackToReTranscribe() async {
        let probe = NemotronFactoryProbe(loadError: LoadFailure())
        let engine = LoadTrackingEngine()
        let captions = LiveCaptionsState()
        let controller = makeController(probe: probe, engine: engine, captions: captions)

        await controller.prepare()

        XCTAssertGreaterThan(probe.buildCount, 0, "the Nemotron path must have been attempted")
        XCTAssertEqual(
            engine.loadModelCount, 1,
            "Nemotron load failure must fall back to the re-transcribe path, which loads the engine",
        )
        XCTAssertEqual(
            captions.activeBackend, "Re-transcribe · DE",
            "a silent fallback must publish the ACTUAL backend, not the selected Nemotron",
        )
    }

    func testPrepareThenResetKeepsNemotronSessions() async {
        let probe = NemotronFactoryProbe()
        let engine = LoadTrackingEngine()
        let controller = makeController(probe: probe, engine: engine)

        await controller.prepare()
        await controller.prepareForNextRecording()

        XCTAssertEqual(probe.buildCount, 1, "a kept streaming session must NOT be rebuilt for the next recording")
        XCTAssertEqual(engine.loadModelCount, 0, "the kept Nemotron session path must not load the engine")
    }
}
