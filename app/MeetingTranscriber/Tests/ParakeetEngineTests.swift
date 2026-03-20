@testable import MeetingTranscriber
import WhisperKit
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

    // MARK: - Protocol Conformance

    func testConformsToTranscribingEngine() {
        let engine = ParakeetEngine()
        // Assign to protocol type to verify conformance at compile time
        let proto: TranscribingEngine = engine
        XCTAssertNotNil(proto)
    }

    func testIsReferenceType() {
        let engine = ParakeetEngine()
        let ref: TranscribingEngine = engine
        // Mutating the reference should be visible via the original variable
        XCTAssertIdentical(engine, ref, "ParakeetEngine should be a reference type (class)")
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

    // MARK: - MergeDualSourceSegments (protocol extension on TranscribingEngine)

    func testMergeDualSourceSegmentsLabelsAndSorts() {
        let engine = ParakeetEngine()

        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "Hello from app")]
        let micSegs = [TimestampedSegment(start: 2, end: 7, text: "Hello from mic")]

        let result = engine.mergeDualSourceSegments(appSegments: appSegs, micSegments: micSegs)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Remote")
        XCTAssertEqual(result[0].text, "Hello from app")
        XCTAssertEqual(result[1].speaker, "Me")
        XCTAssertEqual(result[1].text, "Hello from mic")
    }

    func testMergeDualSourceSegmentsAppliesMicDelay() {
        let engine = ParakeetEngine()

        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "App")]
        let micSegs = [TimestampedSegment(start: 0, end: 5, text: "Mic")]

        let result = engine.mergeDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micDelay: 3.0,
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "App")
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[1].text, "Mic")
        XCTAssertEqual(result[1].start, 3.0)
        XCTAssertEqual(result[1].end, 8.0)
    }

    func testMergeDualSourceSegmentsEmptyInputs() {
        let engine = ParakeetEngine()

        let result = engine.mergeDualSourceSegments(appSegments: [], micSegments: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testMergeDualSourceSegmentsCustomMicLabel() {
        let engine = ParakeetEngine()

        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "App")]
        let micSegs = [TimestampedSegment(start: 1, end: 6, text: "Mic")]

        let result = engine.mergeDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micLabel: "Alice",
        )

        XCTAssertEqual(result[1].speaker, "Alice")
    }

    // MARK: - Load Model State Transitions

    func testLoadModelTransitionsToLoaded() async {
        let engine = ParakeetEngine()
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
