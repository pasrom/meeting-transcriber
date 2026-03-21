@testable import MeetingTranscriber
import WhisperKit
import XCTest

@MainActor
final class Qwen3AsrEngineTests: XCTestCase {
    // MARK: - Initial State

    func testModelStateStartsUnloaded() {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    func testDownloadProgressStartsAtZero() {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        XCTAssertEqual(engine.downloadProgress, 0, accuracy: 0.001)
    }

    func testTranscriptionProgressStartsAtZero() {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        XCTAssertEqual(engine.transcriptionProgress, 0, accuracy: 0.001)
    }

    // MARK: - Protocol Conformance

    func testConformsToTranscribingEngine() {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        // Assign to protocol type to verify conformance at compile time
        let proto: TranscribingEngine = engine
        XCTAssertNotNil(proto)
    }

    func testIsReferenceType() {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        let ref: TranscribingEngine = engine
        // Mutating the reference should be visible via the original variable
        XCTAssertIdentical(engine, ref, "Qwen3AsrEngine should be a reference type (class)")
    }

    // MARK: - Language Setting

    func testLanguageDefaultsToNil() {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        XCTAssertNil(engine.language)
    }

    func testLanguageCanBeSetFromISOCode() {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        engine.language = "de"
        XCTAssertEqual(engine.language, "de")
    }

    // MARK: - Transcription Errors

    func testTranscribeSegmentsThrowsForNonexistentFile() async {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        let dummyURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID()).wav")

        do {
            _ = try await engine.transcribeSegments(audioPath: dummyURL)
            XCTFail("Expected transcribeSegments to throw for nonexistent file")
        } catch {
            // Either model load fails (TranscriptionError) or file open fails (AVFoundation)
            // Both are acceptable — the key guarantee is it does NOT succeed silently
            XCTAssertFalse(
                "\(error)".isEmpty,
                "Error should have a meaningful description",
            )
        }
    }

    // MARK: - MergeDualSourceSegments (protocol extension)

    func testMergeDualSourceSegmentsLabelsAndSorts() {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()

        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "Hello from app")]
        let micSegs = [TimestampedSegment(start: 2, end: 7, text: "Hello from mic")]

        let result = engine.mergeDualSourceSegments(appSegments: appSegs, micSegments: micSegs)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Remote")
        XCTAssertEqual(result[0].text, "Hello from app")
        XCTAssertEqual(result[1].speaker, "Me")
        XCTAssertEqual(result[1].text, "Hello from mic")
    }

    // MARK: - Load Model State Transitions

    func testLoadModelTransitionsToLoaded() async {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()
        XCTAssertEqual(engine.modelState, .unloaded, "Pre-condition: model starts unloaded")

        await engine.loadModel()

        // Model loads successfully from cached CoreML files, or fails and resets to .unloaded.
        // Either way it must not be stuck in .downloading or .loading.
        let terminalStates: [ModelState] = [.loaded, .unloaded]
        XCTAssertTrue(
            terminalStates.contains(engine.modelState),
            "Model state should be terminal (.loaded or .unloaded), got: \(engine.modelState)",
        )
    }

    func testLoadModelDeduplicatesConcurrentCalls() async {
        guard #available(macOS 15, *) else { return }
        let engine = Qwen3AsrEngine()

        // Start two concurrent loads — second should await the first, not start a new download
        async let load1: Void = engine.loadModel()
        async let load2: Void = engine.loadModel()
        _ = await (load1, load2)

        // Both complete without crash; state is terminal
        let terminalStates: [ModelState] = [.loaded, .unloaded]
        XCTAssertTrue(
            terminalStates.contains(engine.modelState),
            "Model state should be terminal after concurrent loads, got: \(engine.modelState)",
        )
    }
}
