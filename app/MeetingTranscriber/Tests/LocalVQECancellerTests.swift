// Tests for LocalVQECanceller, the EchoCancelling seam over the vendored
// LocalVQE C API. The always-on tests exercise the linked static library
// (context creation failure + error reporting) without any model file. Tests
// that need a real .gguf model skip unless MEETINGTRANSCRIBER_LOCALVQE_MODEL
// points at one — the model is not bundled with the repository.
@testable import MeetingTranscriber
import XCTest

final class LocalVQECancellerTests: XCTestCase {
    // MARK: - Always-on (no model required)

    func testEmptyInputReturnsEmptyWithoutLoadingTheModel() async throws {
        // A nonexistent model path proves the short-circuit: reaching
        // localvqe_new would throw modelLoadFailed instead.
        let canceller = LocalVQECanceller(modelPath: "/nonexistent/model.gguf")
        let out = try await canceller.cancelEcho(mic: [], reference: [])
        XCTAssertEqual(out, [])
    }

    func testMissingModelThrowsModelLoadFailedWithLibraryMessage() async {
        let canceller = LocalVQECanceller(modelPath: "/nonexistent/model.gguf")
        do {
            _ = try await canceller.cancelEcho(mic: [0.1, 0.2], reference: [0.1, 0.2])
            XCTFail("expected modelLoadFailed")
        } catch let EchoCancellationError.modelLoadFailed(message) {
            // The message comes from localvqe_last_error — pin only that the
            // plumbing carries something through, not the exact wording.
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Model-gated (skip when no .gguf is available)

    func testOutputMatchesInputLengthIncludingPartialTrailingHop() async throws {
        let model = try requireLocalVQEModel()
        let farEnd = EchoTestAudio.speechLike(seconds: 2, seed: 7)
        // Deliberately not a multiple of the 256-sample hop.
        let mic = Array(farEnd.prefix(farEnd.count - 100))
        let out = try await LocalVQECanceller(modelPath: model)
            .cancelEcho(mic: mic, reference: farEnd)
        XCTAssertEqual(out.count, mic.count)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
    }

    func testPureEchoIsAttenuated() async throws {
        let model = try requireLocalVQEModel()
        let farEnd = EchoTestAudio.speechLike(seconds: 4, seed: 11)
        // Mic hears only the loudspeaker at reduced level — the canonical
        // far-end-only case every AEC must attenuate.
        let mic = EchoTestAudio.bleed(farEnd, delayMs: 0, gain: 0.5)
        let out = try await LocalVQECanceller(modelPath: model)
            .cancelEcho(mic: mic, reference: farEnd)
        // Ignore the first second: the canceller converges from zero state.
        let settled = EchoTestAudio.rate
        let beforeDb = AudioMixer.rmsDecibels(samples: Array(mic[settled...]))
        let afterDb = AudioMixer.rmsDecibels(samples: Array(out[settled...]))
        // Measured ~50 dB on this signal with the 200K AEC model; the 6 dB
        // floor is a plumbing gate with wide headroom, not a quality bar.
        XCTAssertGreaterThan(
            beforeDb - afterDb, EchoReductionVerdict.minReductionDb,
            "echo-only input should drop by more than the probe floor",
        )
    }

    func testCancellationStopsTheFrameLoop() async throws {
        let model = try requireLocalVQEModel()
        let farEnd = EchoTestAudio.speechLike(seconds: 2, seed: 3)
        let mic = EchoTestAudio.bleed(farEnd, delayMs: 0, gain: 0.5)
        let task = Task {
            try await LocalVQECanceller(modelPath: model)
                .cancelEcho(mic: mic, reference: farEnd)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testShortReferenceIsZeroPaddedNotCrashing() async throws {
        let model = try requireLocalVQEModel()
        let mic = EchoTestAudio.speechLike(seconds: 1, seed: 5)
        let reference = Array(mic.prefix(1000))
        let out = try await LocalVQECanceller(modelPath: model)
            .cancelEcho(mic: mic, reference: reference)
        XCTAssertEqual(out.count, mic.count)
    }
}
