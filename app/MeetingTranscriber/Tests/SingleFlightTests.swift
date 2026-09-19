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
        await Task.yield() // let `second` reach its `await existing.value`
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
}
