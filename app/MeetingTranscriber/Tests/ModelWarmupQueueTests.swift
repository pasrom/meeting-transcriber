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
        async let first: Void = queue.run("test", op(1))
        async let second: Void = queue.run("test", op(2))
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
            await queue.run("test") { log.add("op\(id)") }
        }
        XCTAssertEqual(log.events, ["op1", "op2", "op3", "op4"])
    }

    /// `run` must await its op's completion (the "await until loaded" contract
    /// callers depend on). A fire-and-forget queue would return before `done`.
    func testRunAwaitsOperationCompletion() async {
        let queue = ModelWarmupQueue()
        var done = false
        await queue.run("test") {
            await Task.yield()
            done = true
        }
        XCTAssertTrue(done, "run must not return until its op has finished")
    }

    // MARK: - Stall deadline

    /// The deadline is armed when the op starts and passes once while it still
    /// runs: the stall is reported, and the op is left running.
    func testAnOpStillRunningAtTheDeadlineReportsItsStall() async {
        let deadline = ManualDeadline()
        let queue = ModelWarmupQueue(stallDeadline: .seconds(42), sleep: deadline.sleep)
        let load = MainActorGate()
        let stalls = EventLog()
        let onStall: @MainActor () -> Void = { stalls.add("stall") }
        let run = Task { await queue.run("held", onStall: onStall) { await load.wait() } }
        await waitFor(load.hasWaiter && deadline.waiting == 1)
        XCTAssertEqual(deadline.requested, [.seconds(42)], "the configured deadline must be the one waited for")
        XCTAssertEqual(stalls.events, [], "test premise: the deadline has not passed")

        deadline.pass()
        await waitFor(!stalls.events.isEmpty)

        XCTAssertEqual(stalls.events, ["stall"])
        XCTAssertTrue(load.hasWaiter, "reporting the stall must not end the op")
        load.open()
        await run.value
    }

    /// A deadline that passes after its op finished reports nothing, also when
    /// the sleep returns instead of throwing on cancellation.
    func testAnOpFinishedBeforeTheDeadlineReportsNoStall() async {
        let deadline = ManualDeadline()
        let queue = ModelWarmupQueue(sleep: deadline.sleep)
        let stalls = EventLog()
        let onStall: @MainActor () -> Void = { stalls.add("stall") }
        await queue.run("quick", onStall: onStall) {}
        XCTAssertEqual(deadline.waiting, 1, "test premise: the deadline still waits")

        deadline.pass()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(stalls.events, [])
    }

    /// Time spent waiting behind another op does not count: an op that has not
    /// started has not armed its deadline.
    func testTheDeadlineIsArmedWhenTheOpStartsNotWhenItIsQueued() async {
        let deadline = ManualDeadline()
        let queue = ModelWarmupQueue(sleep: deadline.sleep)
        let first = MainActorGate()
        let firstRun = Task { await queue.run("first") { await first.wait() } }
        await waitFor(first.hasWaiter && deadline.waiting == 1)
        let second = MainActorGate()
        let secondRun = Task { await queue.run("second") { await second.wait() } }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertFalse(second.hasWaiter, "test premise: the second op waits behind the first")

        XCTAssertEqual(deadline.requested.count, 1, "only the running op may have armed its deadline")
        first.open()
        await waitFor(second.hasWaiter && deadline.requested.count == 2)
        XCTAssertEqual(deadline.requested.count, 2, "the second op arms its own deadline once it starts")
        second.open()
        await firstRun.value
        await secondRun.value
        deadline.pass()
    }

    // MARK: - A stalled op gives up its place

    /// An op that never returns must not hold the ops after it forever, and
    /// giving up its place must not end it.
    func testAnOpPastTheDeadlineNoLongerHoldsTheQueue() async {
        let deadline = ManualDeadline()
        let queue = ModelWarmupQueue(sleep: deadline.sleep)
        let stuck = MainActorGate()
        let stuckRun = Task { await queue.run("stuck") { await stuck.wait() } }
        await waitFor(stuck.hasWaiter && deadline.waiting == 1)
        let log = EventLog()
        let nextRun = Task { await queue.run("next") { log.add("next") } }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(log.events, [], "test premise: before the deadline the next op waits")

        deadline.pass()
        await waitFor(log.events == ["next"])

        XCTAssertEqual(log.events, ["next"])
        XCTAssertTrue(stuck.hasWaiter, "the stalled op must keep running")
        stuck.open()
        await stuckRun.value
        await nextRun.value
        deadline.pass()
    }

    /// Only the stalled op is left behind: the ops after it are still serial,
    /// and the stalled op finishing later does not let a third op past the second.
    func testOpsAfterAStalledOneStaySerial() async {
        let deadline = ManualDeadline()
        let queue = ModelWarmupQueue(sleep: deadline.sleep)
        let stuck = MainActorGate()
        let stuckRun = Task { await queue.run("stuck") { await stuck.wait() } }
        await waitFor(stuck.hasWaiter && deadline.waiting == 1)
        let second = MainActorGate()
        let secondRun = Task { await queue.run("second") { await second.wait() } }
        let log = EventLog()
        let thirdRun = Task { await queue.run("third") { log.add("third") } }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        deadline.pass()
        await waitFor(second.hasWaiter)
        XCTAssertTrue(second.hasWaiter, "test premise: the second op runs once the first stalled")
        stuck.open()
        await stuckRun.value
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(log.events, [], "the third op must still wait for the second")

        second.open()
        await secondRun.value
        await thirdRun.value
        XCTAssertEqual(log.events, ["third"])
        deadline.pass()
    }
}

/// A stall deadline the test passes by hand. It ignores cancellation, as a
/// sleep that returns just as its op finishes would, so the queue's own check
/// is what keeps a finished op from reporting a stall.
@MainActor
final class ManualDeadline {
    private(set) var requested: [Duration] = []
    private var pending: [CheckedContinuation<Void, Never>] = []

    var waiting: Int {
        pending.count
    }

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { pending.append($0) }
    }

    /// The deadline passes for every op waiting on it.
    func pass() {
        let due = pending
        pending = []
        for continuation in due {
            continuation.resume()
        }
    }
}
