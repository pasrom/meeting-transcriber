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
    private func mockControllerFactory() -> LiveTranscriptionCoordinator.ControllerFactory {
        { engine, captions, verboseDiagnostics in
            LiveTranscriptionController(
                engine: engine,
                vad: FluidVAD(threshold: 0.5),
                captions: captions,
                speakerMatcher: FakeLiveSpeakerMatcher(),
            ) { verboseDiagnostics() }
        }
    }

    func testAttachSinksInstallsWhenGateOpenAndControllerReady() {
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() }

        let recorder = DualSourceRecorder()
        coordinator.attachSinks(to: recorder)

        XCTAssertNotNil(recorder.micLiveSink, "gate open + controller ready should install the mic sink")
        XCTAssertNotNil(recorder.appLiveSink, "gate open + controller ready should install the app sink")
    }

    func testAttachSinksSkipsWhenLiveDisabledEvenWithControllerReady() {
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
        coordinator.attachSinks(to: recorder)

        XCTAssertNil(recorder.micLiveSink, "live disabled must skip sink install even with a cached controller")
        XCTAssertNil(recorder.appLiveSink)
    }

    func testAttachSinksSkipsWhenEngineUnsupportedEvenWithControllerReady() {
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
        coordinator.attachSinks(to: recorder)

        XCTAssertNil(recorder.micLiveSink, "unsupported engine must skip sink install even with a cached controller")
        XCTAssertNil(recorder.appLiveSink)
    }
}
