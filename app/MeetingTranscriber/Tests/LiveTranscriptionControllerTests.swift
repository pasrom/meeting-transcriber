@testable import MeetingTranscriber
import WhisperKit
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
        let onController = LiveTranscriptionController(
            engine: MockStreamingEngine(),
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
        ) {
            onCalls.increment()
            return true
        }
        await onController.prepare()
        XCTAssertGreaterThan(onCalls.value, 0)

        // (3) Gate-off mirror: the closure is also consulted when it
        // returns false. Catches a regression where someone short-circuits
        // to `if false` upstream, which would make a later flip-to-true
        // a silent no-op.
        let offCalls = VerboseCounter()
        let offController = LiveTranscriptionController(
            engine: MockStreamingEngine(),
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
        ) {
            offCalls.increment()
            return false
        }
        await offController.prepare()
        XCTAssertGreaterThan(offCalls.value, 0)
        XCTAssertNotNil(offController)
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
    var modelState: ModelState = .loaded
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
