@testable import AudioTapLib
@preconcurrency import AVFoundation
import Foundation
import XCTest

/// Regression tests for the input-less-host `deinit` crash. `stop()` (invoked
/// from `deinit`) used to call `engine.inputNode.removeTap` unconditionally, and
/// accessing `AVAudioEngine.inputNode` raises an uncatchable NSException on a
/// host with no input device (a headless CI runner / Mac mini without a mic).
/// `AudioCaptureSession.start()` drops its local `mic` the instant
/// `mic.start()` throws `.noInputDevice`, running the drop straight into
/// `deinit` → `stop()` on exactly that host. `stop()` must skip the tap
/// teardown when the engine never started.
///
/// These are why the handler could not be instantiated in tests before the fix:
/// the CI runner has no input device, so a bare `MicCaptureHandler()` + drop
/// crashed the whole test process on `deinit`.
final class MicCaptureHandlerStopTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-stop-\(UUID().uuidString).wav")
    }

    func testStopWithoutSuccessfulStartDoesNotTouchInputTap() {
        // Inject a spy for the tap removal so the guard is observable on ANY
        // host: a dev Mac HAS an input device, so the real `inputNode` access
        // would not crash here — only the spy makes the skip assertable.
        final class Box: @unchecked Sendable { var calls = 0 }
        let box = Box()
        // Typed local (not a trailing closure) so SwiftFormat can't restyle the
        // labelled argument into a trailing closure.
        let spyRemove: (AVAudioEngine) -> Void = { _ in box.calls += 1 }
        let handler = MicCaptureHandler(outputURL: tempURL(), removeInputTap: spyRemove)

        handler.stop() // never started → must not remove the input tap

        XCTAssertEqual(box.calls, 0, "stop() must not touch the input tap when the engine never started")
    }

    func testDroppedHandlerRunsDeinitStopWithoutCrash() {
        // The exact production path: create a handler whose start() never
        // succeeded (mirrors AudioCaptureSession dropping the local `mic` after
        // `.noInputDevice`), drop it, and let `deinit` → `stop()` run with the
        // real (default) tap remover. On an input-less host this raised an
        // NSException before the fix; here it must simply complete.
        autoreleasepool {
            let handler = MicCaptureHandler(outputURL: tempURL())
            _ = handler // keep alive to the end of the scope, then deinit → stop()
        }
        // Reaching here without crashing is the assertion.
    }
}
