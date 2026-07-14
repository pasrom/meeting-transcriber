@testable import MeetingTranscriber
import XCTest

/// `ModelWarmupQueue` serializes model warm-up loads so the ASR engine and the
/// live-caption streaming models don't compile/load concurrently at launch (the
/// simultaneous ANE + CoreML-compiler peak that starves the system on a meeting
/// join). These tests pin the two load-bearing guarantees: submitted ops never
/// overlap, and `run` awaits its op (so callers keep their "await until loaded"
/// contract).
@MainActor
final class ModelWarmupQueueTests: XCTestCase {
    /// Records op lifecycle events in submission-independent order.
    @MainActor
    private final class EventLog {
        var events: [String] = []
        func add(_ event: String) {
            events.append(event)
        }
    }

    /// Two ops submitted concurrently must run one-at-a-time: each op's `enter`
    /// and `exit` stay contiguous (no interleaving), even though each op yields
    /// in the middle. A non-serializing queue (fire-and-forget) would interleave
    /// them to `[enter1, enter2, ...]`, so this fails against that stub.
    func testRunsSubmittedOperationsSeriallyNeverInterleaved() async {
        let queue = ModelWarmupQueue()
        let log = EventLog()
        func op(_ id: Int) -> @MainActor () async -> Void {
            {
                log.add("enter\(id)")
                await Task.yield()
                await Task.yield()
                log.add("exit\(id)")
            }
        }

        // Submit both without awaiting the first: only the queue can serialize them.
        async let first: Void = queue.run(op(1))
        async let second: Void = queue.run(op(2))
        _ = await (first, second)

        // Order between the two ops is not guaranteed, but they must not overlap.
        XCTAssertTrue(
            log.events == ["enter1", "exit1", "enter2", "exit2"]
                || log.events == ["enter2", "exit2", "enter1", "exit1"],
            "ops must run serially without interleaving; got \(log.events)",
        )
    }

    /// FIFO: sequential submissions preserve order.
    func testPreservesSubmissionOrder() async {
        let queue = ModelWarmupQueue()
        let log = EventLog()
        for id in 1 ... 4 {
            await queue.run { log.add("op\(id)") }
        }
        XCTAssertEqual(log.events, ["op1", "op2", "op3", "op4"])
    }

    /// `run` must await its op's completion (the "await until loaded" contract
    /// callers depend on). A fire-and-forget queue would return before `done`.
    func testRunAwaitsOperationCompletion() async {
        let queue = ModelWarmupQueue()
        var done = false
        await queue.run {
            await Task.yield()
            done = true
        }
        XCTAssertTrue(done, "run must not return until its op has finished")
    }
}
