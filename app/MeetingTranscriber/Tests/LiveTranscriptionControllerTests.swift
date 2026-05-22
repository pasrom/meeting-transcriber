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
@MainActor
final class LiveTranscriptionControllerTests: XCTestCase {
    /// The production-default constructor takes no `verboseDiagnostics`
    /// argument — callers that don't care about log emission rely on the
    /// closure defaulting to `{ false }`. Pins the back-compat signature so
    /// a future refactor that drops the default value gets caught here
    /// rather than at every call site.
    func testControllerBuildsWithDefaultVerboseClosureOff() async {
        let engine = MockStreamingEngine()
        let captions = LiveCaptionsState()
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
        )
        await controller.prepare()
        XCTAssertNotNil(controller.micSink)
        XCTAssertNotNil(controller.appSink)
        XCTAssertTrue(captions.recentFinals.isEmpty)
    }

    /// Pins that the verboseDiagnostics closure is actually wired into
    /// the controller (not silently hard-coded to false somewhere). The
    /// closure is consulted whenever a logger.info would otherwise emit
    /// caption text — `prepare()` itself emits a "ready" log gated on the
    /// same closure, so seeing at least one invocation here proves the
    /// gate is connected. A regression that drops the parameter or always
    /// uses `false` would flip this to zero.
    func testVerboseClosureIsConsulted() async {
        let engine = MockStreamingEngine()
        let captions = LiveCaptionsState()
        let verboseCalls = VerboseCounter()
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
        ) {
            verboseCalls.increment()
            return true
        }
        await controller.prepare()
        XCTAssertGreaterThan(verboseCalls.value, 0)
        XCTAssertNotNil(controller)
    }

    /// Mirror of `testVerboseClosureIsConsulted` for the off path: when
    /// the closure returns false, the controller still calls it
    /// (otherwise the gate isn't doing its job — false would be hardcoded
    /// upstream and a future flip-to-true wouldn't take effect). This
    /// pins symmetry: gate is read on every potential log site, decision
    /// is left to the closure.
    func testVerboseClosureIsConsultedWhenOff() async {
        let engine = MockStreamingEngine()
        let captions = LiveCaptionsState()
        let verboseCalls = VerboseCounter()
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
        ) {
            verboseCalls.increment()
            return false
        }
        await controller.prepare()
        XCTAssertGreaterThan(verboseCalls.value, 0)
        XCTAssertNotNil(controller)
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
