@testable import MeetingTranscriber
import XCTest

/// Parakeet's side of a job cancelled while the model loads: the job ends at
/// once, the load runs on for the next caller, and a job already cancelled
/// still starts it. The load is replaced by one parked on a gate the test
/// opens, so nothing is downloaded and no verdict rests on timing.
@MainActor
final class ParakeetEngineCancelledLoadTests: XCTestCase {
    private var loads = 0
    private let gate = MainActorGate()

    private func makeEngine() -> ParakeetEngine {
        let engine = ParakeetEngine()
        engine.installModelLoadForTesting { [self] in
            loads += 1
            await gate.wait()
        }
        return engine
    }

    func testACancelledTranscriptionDoesNotWaitForTheModelLoad() async {
        let engine = makeEngine()
        let job = Task { @MainActor in
            await outcome { _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/dev/null")) }
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        job.cancel()
        let jobOutcome = await value(of: job)

        XCTAssertEqual(jobOutcome, "cancelled", "the cancelled job waited for the model load")

        // Opened from inside the next caller, so it joins the parked load by
        // construction (see the WhisperKit counterpart).
        let next = Task { @MainActor in
            gate.open()
            await engine.loadModel()
            return true
        }
        let nextReturned = await value(of: next)

        XCTAssertNotNil(nextReturned, "the next caller did not return once the load finished")
        XCTAssertEqual(loads, 1, "the next caller loaded again instead of joining the load")
    }

    func testAnAlreadyCancelledTranscriptionStillStartsTheLoad() async {
        let engine = makeEngine()
        let job = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await outcome {
                _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/dev/null"))
            }
        }
        let jobOutcome = await value(of: job)
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)

        XCTAssertEqual(jobOutcome, "cancelled")
        XCTAssertTrue(gate.hasWaiter, "a cancelled job did not start the load")
        gate.open()
    }
}
