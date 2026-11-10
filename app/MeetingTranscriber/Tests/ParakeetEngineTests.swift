@testable import MeetingTranscriber
import XCTest

@MainActor
final class ParakeetEngineTests: XCTestCase {
    // MARK: - Initial State

    func testModelStateStartsUnloaded() {
        let engine = ParakeetEngine()
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    func testDownloadProgressStartsAtZero() {
        let engine = ParakeetEngine()
        XCTAssertEqual(engine.downloadProgress, 0, accuracy: 0.001)
    }

    func testTranscriptionProgressStartsAtZero() {
        let engine = ParakeetEngine()
        XCTAssertEqual(engine.transcriptionProgress, 0, accuracy: 0.001)
    }

    // MARK: - Transcription Errors

    func testTranscribeSegmentsThrowsForNonexistentFile() async {
        let engine = ParakeetEngine()
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

    // MARK: - Load Model State Transitions

    func testLoadModelTransitionsToLoaded() async {
        let engine = ParakeetEngine()
        XCTAssertEqual(engine.modelState, .unloaded, "Pre-condition: model starts unloaded")

        await engine.loadModel()

        // Model loads successfully from cached CoreML files, or fails and resets to .unloaded.
        // Either way it must not be stuck in .downloading or .loading.
        let terminalStates: [EngineModelState] = [.loaded, .unloaded]
        XCTAssertTrue(
            terminalStates.contains(engine.modelState),
            "Model state should be terminal (.loaded or .unloaded), got: \(engine.modelState)",
        )
    }

    func testDownloadProgressAfterLoad() async {
        let engine = ParakeetEngine()

        await engine.loadModel()

        if engine.modelState == .loaded {
            XCTAssertEqual(engine.downloadProgress, 1.0, accuracy: 0.001)
        } else {
            // Failed load resets progress to 0
            XCTAssertEqual(engine.downloadProgress, 0, accuracy: 0.001)
        }
    }

    func testLoadModelDeduplicatesConcurrentCalls() async {
        let engine = ParakeetEngine()
        let gate = MainActorGate()
        var loads = 0
        engine.installModelLoadForTesting {
            loads += 1
            await gate.wait()
        }

        let first = Task { @MainActor in await engine.loadModel() }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        // Opened from inside the second caller, so it reaches the join before
        // the parked load can finish: a second load here is a missing join, not
        // a race lost.
        let second = Task { @MainActor in
            gate.open()
            await engine.loadModel()
        }
        await first.value
        await second.value

        XCTAssertEqual(loads, 1, "the second caller started its own load instead of joining the first")
    }
}
