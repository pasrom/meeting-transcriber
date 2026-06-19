@testable import MeetingTranscriber
import XCTest

/// Unit tests for `LiveTranscriptionCoordinator.attachSinks`'s gate — that live
/// sinks are installed on the recorder IFF the toggle is on AND the active engine
/// supports streaming.
///
/// This gating was previously buried in `AppState.makeRecorderFactory` (a private
/// closure) and only reachable via live recording / E2E. The `makeController`
/// injection seam lets a test supply a controller built with mock collaborators
/// (`MockStreamingEngine` + `FakeLiveSpeakerMatcher`) so `prepare()` loads no
/// models — making the gate testable in isolation.
///
/// Non-vacuity: the two "skip" tests build the controller with the gate OPEN
/// (so it's cached), then flip the gate CLOSED before `attachSinks`. The sinks
/// stay nil *because of the gate*, not because no controller exists — removing
/// the gate would install them (proven by temporarily deleting the guard).
@MainActor
final class LiveTranscriptionCoordinatorTests: XCTestCase {
    /// Builds a controller with mock collaborators — `prepare()` is a no-op
    /// (mock engine `loadModel`, fake matcher `prepare`), so no model loads.
    /// The EOU factory returns a mock manager that never loads real models, so
    /// the English-streaming branch is exercisable without CoreML downloads.
    private func mockControllerFactory() -> LiveTranscriptionCoordinator.ControllerFactory {
        { engine, captions, engineLanguage, verboseDiagnostics in
            let eouFactory: LiveTranscriptionController.EouSessionFactory = { MockEouManager() }
            let verbose: () -> Bool = { verboseDiagnostics() }
            return LiveTranscriptionController(
                engine: engine,
                vad: FluidVAD(threshold: 0.5),
                captions: captions,
                speakerMatcher: FakeLiveSpeakerMatcher(),
                engineLanguage: engineLanguage,
                eouSessionFactory: eouFactory,
                verboseDiagnostics: verbose,
            )
        }
    }

    func testAttachSinksInstallsWhenGateOpenAndControllerReady() async {
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() }

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertNotNil(recorder.micLiveSink, "gate open + controller ready should install the mic sink")
        XCTAssertNotNil(recorder.appLiveSink, "gate open + controller ready should install the app sink")
    }

    func testAttachSinksSkipsWhenLiveDisabledEvenWithControllerReady() async {
        var enabled = true
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { enabled },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() } // gate open → controller cached
        enabled = false

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertNil(recorder.micLiveSink, "live disabled must skip sink install even with a cached controller")
        XCTAssertNil(recorder.appLiveSink)
    }

    func testAttachSinksSkipsWhenEngineUnsupportedEvenWithControllerReady() async {
        var supportsLive = true
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { supportsLive },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() } // gate open → controller cached
        supportsLive = false

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertNil(recorder.micLiveSink, "unsupported engine must skip sink install even with a cached controller")
        XCTAssertNil(recorder.appLiveSink)
    }

    /// English-streaming opt-in bypasses the engine-support gate: with the
    /// engine reporting no live support, `attachSinks` still installs the sinks
    /// because the EOU sessions are engine-independent. The non-vacuity twin of
    /// `testAttachSinksSkipsWhenEngineUnsupportedEvenWithControllerReady` — same
    /// unsupported engine, but `englishStreaming` ON flips the outcome.
    func testAttachSinksInstallsWhenEngineUnsupportedButEnglishStreamingOn() async {
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { false },
            engineLanguage: { "en" },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        // Non-streaming engine provider: the EOU path
        // builds a controller with a nil streaming engine, so the sinks still
        // install. `nil` here would short-circuit ensureController before the
        // gate, so use a non-streaming stand-in.
        coordinator.beginPrewarm { NonStreamingEngine() }

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertNotNil(
            recorder.micLiveSink,
            "english streaming must bypass the engine-support gate and install the mic sink",
        )
        XCTAssertNotNil(recorder.appLiveSink)
    }
}

/// A `TranscribingEngine` that does NOT conform to `StreamingTranscribingEngine`
/// — for which the English-streaming path must build a controller with a nil
/// streaming engine.
@MainActor
private final class NonStreamingEngine: TranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1.0
    var transcriptionProgress: Double = 1.0
    func loadModel() {}
    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }
}
