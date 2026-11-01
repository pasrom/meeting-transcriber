@testable import MeetingTranscriber
import XCTest

/// A job cancelled while the engine is still loading its model: it must end at
/// once, since the first download or the CoreML compile can take minutes and
/// the queue starts nothing else until the job ends; the shared pass must run
/// on for the next job; and the cancelled job must start no further pass.
/// The load is parked on a gate the test opens, so no verdict rests on timing.
@MainActor
final class WhisperKitEngineCancelledLoadTests: XCTestCase {
    /// The cancelled job returns while the load is still parked, and the next
    /// caller joins that load instead of building the model a second time.
    func testACancelledTranscriptionDoesNotWaitForTheModelLoad() async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let local = try makeTempDirectory(prefix: "wk-local")
        let gate = MainActorGate()
        let recorder = try await installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .success(makeIdlePipe()),
            // swiftlint:disable:next trailing_closure
            onPipe: { _ in await gate.wait() },
        )

        let job = Task { @MainActor in
            await outcome { _ = try await engine.transcribeSegments(audioPath: local.appendingPathComponent("a.wav")) }
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        job.cancel()
        let jobOutcome = await value(of: job)

        XCTAssertEqual(jobOutcome, "cancelled", "the cancelled job waited for the model load")

        // Opened from inside the next caller: `open()` only enqueues the parked
        // load, so the caller keeps the actor up to its first real suspension,
        // the join inside `SingleFlight`, and joins by construction.
        let next = Task { @MainActor in
            gate.open()
            await engine.loadModel()
            return engine.modelState
        }
        let stateForTheNextCaller = await value(of: next)

        XCTAssertEqual(stateForTheNextCaller, .loaded, "the next caller did not get the model the load produced")
        XCTAssertEqual(
            recorder.pipeVariants, ["openai_whisper-small"],
            "the next caller built the model again instead of joining the load",
        )
    }

    /// The pass the cancelled job started runs to its end, but the retry that a
    /// variant change makes due is the job's own, and nobody waits for it any
    /// more: it must not run. It would download and compile a model outside the
    /// warm-up queue for no one.
    func testACancelledTranscriptionStartsNoFurtherPass() async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let local = try makeTempDirectory(prefix: "wk-local")
        let gate = MainActorGate()
        let recorder = try await installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .success(makeIdlePipe()),
            // swiftlint:disable:next trailing_closure
            onPipe: { _ in await gate.wait() },
        )

        let job = Task { @MainActor in
            await outcome { _ = try await engine.transcribeSegments(audioPath: local.appendingPathComponent("a.wav")) }
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        job.cancel()
        let jobOutcome = await value(of: job)
        engine.applyModelVariant("openai_whisper-tiny")
        gate.open()
        // The pass ends by dropping the pipe it built for the superseded variant.
        await waitFor(engine.modelState == .unloaded, timeout: regressionCeiling)
        // A further pass would be a few main-actor jobs away (the waiter
        // resumed, the loop's next turn, the flight's task). The main actor runs
        // its jobs in order, so each empty job awaited here runs after every job
        // already enqueued: ten of them outlast any such chain, whatever the timing.
        for _ in 0 ..< 10 {
            await Task { @MainActor in }.value
        }

        XCTAssertEqual(jobOutcome, "cancelled")
        XCTAssertEqual(
            recorder.pipeVariants, ["openai_whisper-small"],
            "a pass ran for the new variant although the job that started the load was cancelled",
        )
    }

    /// A job already cancelled when it reaches the model still starts the load,
    /// so the next job finds it under way; it only does not wait for it.
    func testAnAlreadyCancelledTranscriptionStillStartsTheLoad() async throws {
        let engine = WhisperKitEngine()
        let local = try makeTempDirectory(prefix: "wk-local")
        let gate = MainActorGate()
        _ = try await installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .success(makeIdlePipe()),
            // swiftlint:disable:next trailing_closure
            onPipe: { _ in await gate.wait() },
        )

        let job = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await outcome {
                _ = try await engine.transcribeSegments(audioPath: local.appendingPathComponent("a.wav"))
            }
        }
        let jobOutcome = await value(of: job)
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)

        XCTAssertEqual(jobOutcome, "cancelled")
        XCTAssertTrue(gate.hasWaiter, "a cancelled job did not start the load")
        gate.open()
        await waitFor(engine.modelState == .loaded, timeout: regressionCeiling)
        XCTAssertEqual(engine.modelState, .loaded)
    }
}
