import FluidAudio
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

    /// FluidAudio's Silero VAD model lives in a separate HuggingFace repo
    /// from the ASR models, so the engine pre-warms above don't pull it.
    /// Without this, `LiveTranscriptionE2ETests` is the first test to need
    /// it, and three parallel xctest workers race on the same download
    /// (HuggingFace client's `weight.bin.<hash>.incomplete → weights/`
    /// rename is not safe under concurrent fetches → timeouts).
    func testPreloadFluidVAD() async throws {
        let vad = FluidVAD(threshold: 0.5)
        // `makeStreamState()` triggers the same `ensureManager()` /
        // `VadManager(config:)` chain the streaming pipeline goes through;
        // discarding the state is fine — we only care about the side effect
        // of populating the model cache.
        _ = try await vad.makeStreamState()
    }

    /// The Parakeet EOU 320ms streaming models live in their own HuggingFace
    /// repo, separate from the batch Parakeet TDT models the engine pre-warms.
    /// Without this, `EouStreamingE2ETests` is the first test to need them and
    /// a cold CI run would download them inline (and parallel workers would
    /// race the HuggingFace `*.incomplete → weights/` rename). Mirrors the
    /// production backend (`LiveTranscriptionController.makeDefaultEouManager`):
    /// `StreamingEouAsrManager(chunkSize: .ms320)`.
    func testPreloadEouStreaming() async throws {
        let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
        try await manager.loadModels()
    }
}
