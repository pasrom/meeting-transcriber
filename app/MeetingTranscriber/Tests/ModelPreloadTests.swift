@testable import MeetingTranscriber
import XCTest

/// Cache pre-warmer for `swift test --parallel` against a cold ML model
/// cache. Runs sequentially via `--filter ModelPreloadTests` before the
/// main parallel suite (only on CI cache miss); subsequent concurrent
/// loads hit the cache and don't race on the HuggingFace download client's
/// `weight.bin.<hash>.incomplete → weights/` rename.
///
/// Local dev: cache is warm, this is a sub-10s cache check.
@MainActor
final class ModelPreloadTests: XCTestCase {
    func testPreloadWhisperKitDefault() async {
        let engine = WhisperKitEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)
    }

    func testPreloadWhisperKitSmall() async {
        // Variant used by WhisperKitEngineTests / WhisperKitE2ETests.
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)
    }

    func testPreloadParakeet() async {
        let engine = ParakeetEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)
    }

    func testPreloadQwen3() async {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)
    }
}
