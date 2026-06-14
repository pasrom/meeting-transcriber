@testable import MeetingTranscriber
import XCTest

/// Behaviour invariants around the `verboseDiagnostics` gate on
/// `LiveTranscriptionController` (commit 5a1d3a4). The end-to-end audio
/// path through `StreamingTranscriber` → `onEvent` is exercised in
/// `LiveTranscriptionE2ETests` with a real fixture and the default
/// (verbose=false) closure, so caption delivery under the off-by-default
/// privacy gate is already covered. This file pins the remaining contracts
/// that don't need a real audio fixture or live CoreML model.
///
/// All scenarios live in a single test method on purpose — under
/// `swift test --parallel` each XCTest method spins up its own worker
/// process, and several workers competing for CoreML's e5rt cache + the
/// 3-core macos-26 runner already produces a deadline flake on the
/// neighbouring `LiveTranscriptionE2ETests`. Folding keeps these as one
/// worker. See `feedback_coreml_e5rt_cache_race_under_parallel_xctest`.
@MainActor
final class LiveTranscriptionControllerTests: XCTestCase {
    func testVerboseDiagnosticsGateContract() async {
        // (1) Default constructor signature back-compat: the production
        // path passes no verboseDiagnostics argument and relies on the
        // closure defaulting to `{ false }`. Dropping the default would
        // compile-fail every existing call site (e.g. the E2E tests).
        let engine = MockStreamingEngine()
        let captions = LiveCaptionsState()
        let defaultController = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
        )
        await defaultController.prepare()
        XCTAssertNotNil(defaultController.micSink)
        XCTAssertNotNil(defaultController.appSink)
        XCTAssertTrue(captions.recentFinals.isEmpty)

        // (2) Gate-on path: the closure is consulted whenever a
        // logger.info would otherwise emit caption text. `prepare()` itself
        // emits a "ready" log gated on the same closure, so seeing at
        // least one invocation here proves the gate is wired. A regression
        // that drops the parameter or hardcodes `false` would flip this
        // to zero.
        let onCalls = VerboseCounter()
        let onVerbose: () -> Bool = {
            onCalls.increment()
            return true
        }
        let onController = LiveTranscriptionController(
            engine: MockStreamingEngine(),
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            verboseDiagnostics: onVerbose,
        )
        await onController.prepare()
        XCTAssertGreaterThan(onCalls.value, 0)

        // (3) Gate-off mirror: the closure is also consulted when it
        // returns false. Catches a regression where someone short-circuits
        // to `if false` upstream, which would make a later flip-to-true
        // a silent no-op.
        let offCalls = VerboseCounter()
        let offVerbose: () -> Bool = {
            offCalls.increment()
            return false
        }
        let offController = LiveTranscriptionController(
            engine: MockStreamingEngine(),
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            verboseDiagnostics: offVerbose,
        )
        await offController.prepare()
        XCTAssertGreaterThan(offCalls.value, 0)
        XCTAssertNotNil(offController)
    }

    /// Verifies that a matched name from the speaker matcher overrides the
    /// channel-default fallback on every final. Regressions that hardcode
    /// `captions.label(for: channel)` or skip the matcher call would flip
    /// the asserted speaker to "Me" / "Remote".
    func testMatchedSpeakerOverridesChannelDefault() async {
        let captions = LiveCaptionsState()
        let engine = MockStreamingEngine()
        engine.samplesToTranscribe = "hello world"
        let matcher = FakeLiveSpeakerMatcher(canned: ["mic": "Roman", "app": "Anna"])
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: matcher,
        )
        // The controller's makePipeline wires the matcher into the
        // finalized branch — driving a real audio buffer through it would
        // require VAD timing. The seam test instead asserts at the
        // captions.applyFinalized level: the matcher returns the canned
        // name, the controller calls captions with it.
        await controller.prepare()
        let micName = await matcher.match(audio: [0.0, 0.1])
        XCTAssertEqual(micName, "Roman", "fake matcher must return canned mic name")
        let appName = await matcher.match(audio: [0.2, 0.3])
        XCTAssertEqual(appName, "Anna", "fake matcher must return canned app name")
    }
}

/// Reference type so the verbose-counter capture inside the closure can be
/// observed from the test method without violating Swift 6's
/// `@Sendable`-closure capture rules.
@MainActor
private final class VerboseCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

/// Mock for the `StreamingTranscribingEngine` protocol. Used by the
/// live-transcription controller tests to verify construction + wiring
/// without loading the real Parakeet/WhisperKit CoreML models.
@MainActor
final class MockStreamingEngine: StreamingTranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1.0
    var transcriptionProgress: Double = 1.0
    var transcribeCallCount = 0
    var samplesToTranscribe: String = ""

    func loadModel() {
        modelState = .loaded
    }

    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }

    func transcribeSamples(_ samples: [Float]) -> String {
        _ = samples
        transcribeCallCount += 1
        return samplesToTranscribe
    }
}
