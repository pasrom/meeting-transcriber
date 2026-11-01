@testable import MeetingTranscriber
import XCTest

/// Unit tests for the `SingleFlight` concurrency primitive that the two ASR
/// engines share for `loadModel()` deduplication. These pin the dedup +
/// re-arm invariants directly with trivial in-memory bodies — no model loads,
/// so they run in the fast (non-E2E) suite.
@MainActor
final class SingleFlightTests: XCTestCase {
    /// Concurrent callers must run the body exactly once: the second caller
    /// awaits the in-flight run instead of starting its own. The first body is
    /// parked on a continuation so the second call provably overlaps it; a
    /// non-deduping implementation would run the body twice (count 2).
    func test_concurrentCallers_runBodyOnce() async {
        let flight = SingleFlight<Void>()
        var runCount = 0
        let started = expectation(description: "first body entered")
        var release: (() -> Void)?

        let first = Task { @MainActor in
            await flight.run {
                runCount += 1
                started.fulfill()
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    release = { cont.resume() }
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)

        // The first body is parked with the flight's task set. A second call
        // must dedup onto it and never run its own body.
        let second = Task { @MainActor in
            await flight.run { runCount += 1 }
        }
        await Task.yield() // let `second` reach the join on the in-flight task
        release?()
        await first.value
        await second.value

        XCTAssertEqual(runCount, 1)
    }

    /// After a run completes the flight must re-arm: a subsequent call runs the
    /// body again rather than latching onto the finished task. This is the
    /// clear-on-finish invariant — a latched task would replay its result and
    /// the second body would never run (count stays 1).
    func test_sequentialCallers_rerunBody() async {
        let flight = SingleFlight<Void>()
        var runCount = 0
        await flight.run { runCount += 1 }
        await flight.run { runCount += 1 }
        XCTAssertEqual(runCount, 2)
    }

    /// A joiner must receive the outcome of the run it joined, not its own body's.
    ///
    /// This is what lets a caller tell "the run I waited for failed" from "the run
    /// I waited for was for something else": without it, a joiner has no way to
    /// know what the flight it waited on attempted, and the WhisperKit engine
    /// cannot decide whether to try again (issue #738).
    func test_joiner_receivesTheOutcomeOfTheRunItJoined() async {
        let flight = SingleFlight<String>()
        var bodiesRun: [String] = []
        let started = expectation(description: "first body entered")
        var release: (() -> Void)?

        let first = Task { @MainActor in
            await flight.run {
                bodiesRun.append("first")
                started.fulfill()
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    release = { cont.resume() }
                }
                return "first"
            }
        }
        await fulfillment(of: [started], timeout: 2)

        // Resuming the parked body only enqueues it on this actor, so the joiner
        // keeps the actor until its own first real suspension, which is the join
        // itself. The order is therefore fixed by construction, not by luck.
        let second = Task { @MainActor in
            release?()
            return await flight.run {
                bodiesRun.append("second")
                return "second"
            }
        }
        let firstOutcome = await first.value
        let secondOutcome = await second.value

        XCTAssertEqual(bodiesRun, ["first"], "The joiner's body must not run")
        XCTAssertEqual(firstOutcome, "first")
        XCTAssertEqual(
            secondOutcome, "first",
            "The joiner must be told what the run it waited on attempted, not what its own body would have said",
        )
    }

    /// A cancelled `runUnlessCancelled` caller stops waiting while the run is
    /// still parked; the run goes on, uncancelled, and a caller still waiting
    /// gets its outcome.
    func test_cancelledJoiner_stopsWaitingWhileTheRunGoesOn() async {
        let flight = SingleFlight<String>()
        let gate = MainActorGate()
        var runCount = 0
        var runSawACancel = false
        let body: @MainActor () async -> String = {
            runCount += 1
            await gate.wait()
            runSawACancel = Task.isCancelled
            return "loaded"
        }
        let cancelled = Task { @MainActor in
            await outcome { _ = try await flight.runUnlessCancelled(body) }
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        let waiting = Task { @MainActor in try await flight.runUnlessCancelled(body) }

        cancelled.cancel()
        let cancelledOutcome = await value(of: cancelled)
        XCTAssertEqual(cancelledOutcome, "cancelled", "the cancelled caller waited for the run")

        gate.open()
        let outcome = try? await waiting.value
        XCTAssertEqual(outcome, "loaded")
        XCTAssertEqual(runCount, 1)
        XCTAssertFalse(runSawACancel, "the caller's cancel reached the shared run")
    }

    /// A caller already cancelled still starts the run, so it is under way for
    /// whoever comes next; it only does not wait for it.
    func test_alreadyCancelledCaller_startsTheRunWithoutWaiting() async {
        let flight = SingleFlight<Void>()
        let gate = MainActorGate()
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await outcome { try await flight.runUnlessCancelled { await gate.wait() } }
        }

        let callerOutcome = await value(of: caller)
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)

        XCTAssertEqual(callerOutcome, "cancelled")
        XCTAssertTrue(gate.hasWaiter, "a cancelled caller did not start the run")
        gate.open()
    }
}
