@testable import MeetingTranscriber
import os
import XCTest

final class ConsentPromptCoordinatorTests: XCTestCase {
    /// A timeout sleep that only ends when its task is cancelled (an answer
    /// cancels it), so the timeout can't win and the test drives resolution.
    private let neverSleep: @Sendable (TimeInterval) async -> Void = { _ in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    func testResolvesToGrantedAnswer() async {
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "a") {} }
        await yieldUntilParked()
        coord.resolve(id: "a", granted: true)
        let result = await task.value
        XCTAssertEqual(result, .granted)
    }

    func testResolvesToDeniedAnswer() async {
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "b") {} }
        await yieldUntilParked()
        coord.resolve(id: "b", granted: false)
        let result = await task.value
        XCTAssertFalse(result.isGranted)
    }

    /// A timeout is reported as its own answer, not as a decline: the two mean
    /// different things to the re-prompt cooldown (issue #543).
    func testTimeoutIsDistinguishableFromADecline() async {
        let instant: @Sendable (TimeInterval) async -> Void = { _ in }
        let coordinator = ConsentPromptCoordinator(timeout: 0.01, sleep: instant)
        let expired = await coordinator.awaitDecision(id: "a") {}
        XCTAssertEqual(expired, .expired)

        // The timeout here only ends when the decline cancels it. A real sleep
        // could win on a loaded runner, leaving nothing for the decline to find,
        // and an unbounded wait for a prompt that is already gone never ends.
        let answered = ConsentPromptCoordinator(timeout: 5, sleep: neverSleep)
        let task = Task { await answered.awaitDecision(id: "b") {} }
        let deadline = Date().addingTimeInterval(10)
        var parked = false
        repeat {
            parked = answered.resolvePending(granted: false)
            if !parked { try? await Task.sleep(nanoseconds: 5_000_000) }
        } while !parked && Date() < deadline
        guard parked else {
            XCTFail("prompt never parked or already expired")
            return
        }
        let declined = await task.value
        XCTAssertEqual(declined, .declined)
    }

    /// A timeout that fires at once must still find the prompt registered.
    /// The timeout task used to be started before the continuation was stored,
    /// so when the timeout ran first its `resolve` found nothing, the
    /// continuation stored right after was never resumed, and the caller hung
    /// for good. Nothing to inject sits inside that window, so the test widens
    /// it the way a loaded machine does: callers run on a background-priority
    /// thread, their timeout tasks inherit a high priority, and every core is
    /// busy at a priority between the two, so starting a timeout task tends to
    /// preempt its caller right inside the window. Against the old order this
    /// stranded prompts in every run it was tried on; the wait is bounded so
    /// that shows up as a failure, not as a hung suite.
    func testInstantTimeoutNeverStrandsThePrompt() async throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("needs a task executor preference (macOS 15)")
        }
        let instant: @Sendable (TimeInterval) async -> Void = { _ in }
        let coordinator = ConsentPromptCoordinator(timeout: 0, sleep: instant)
        let callerExecutor = BackgroundTaskExecutor()
        let prompts = 300
        let finished = OSAllocatedUnfairLock<Int>(initialState: 0)

        let busy = OSAllocatedUnfairLock<Bool>(initialState: true)
        for _ in 0 ..< ProcessInfo.processInfo.activeProcessorCount * 2 {
            let hog = Thread { while busy.withLock({ $0 }) {} }
            hog.qualityOfService = .default
            hog.start()
        }
        for index in 0 ..< prompts {
            Task(priority: .high) {
                _ = await withTaskExecutorPreference(callerExecutor) {
                    await coordinator.awaitDecision(id: "race-\(index)") {}
                }
                finished.withLock { $0 += 1 }
            }
        }
        // Keep the cores busy until every prompt has finished, for at most a
        // second; a passing run frees them as soon as it can.
        let busyUntil = Date().addingTimeInterval(1)
        while finished.withLock({ $0 }) < prompts, Date() < busyUntil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        busy.withLock { $0 = false }
        // Under a parallel suite the other workers keep the cores busy too, and
        // a background queue can then wait far longer than any bound; lifting
        // it leaves only the prompts that can never finish.
        callerExecutor.raisePriority()

        let deadline = Date().addingTimeInterval(30)
        while finished.withLock({ $0 }) < prompts, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let resolved = finished.withLock { $0 }
        XCTAssertEqual(
            resolved, prompts,
            "\(prompts - resolved) of \(prompts) prompts never resolved: their timeout fired before they were registered",
        )
    }

    func testUnansweredPromptTimesOutToDeny() async {
        // A short real timeout: an unanswered prompt resolves to "don't record".
        let coord = ConsentPromptCoordinator(timeout: 0.02)
        let result = await coord.awaitDecision(id: "c") {}
        XCTAssertFalse(result.isGranted)
    }

    func testSecondResolveIsIgnored() async {
        // Race-safety: the first resolver wins; a second resolve (e.g. the
        // timeout firing just after an answer) must not double-resume the
        // continuation — that would crash.
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "d") {} }
        await yieldUntilParked()
        coord.resolve(id: "d", granted: true)
        coord.resolve(id: "d", granted: false)
        let result = await task.value
        XCTAssertEqual(result, .granted)
    }

    func testResolveForUnknownIdIsNoOp() {
        // Resolving an id that was never awaited must not crash.
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        coord.resolve(id: "never-awaited", granted: true)
    }

    // MARK: - resolvePending (the RPC consent hook — resolve without a prompt id)

    func testResolvePendingWithNoPromptsReturnsFalse() {
        // The RPC test hook has no prompt id and polls: "nothing waiting yet" is
        // a false no-op, not an error, so the driver can retry.
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        XCTAssertFalse(coord.resolvePending(granted: true))
    }

    func testResolvePendingResolvesSingleParkedPrompt() async {
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "a") {} }
        await yieldUntilParked()
        let resolved = coord.resolvePending(granted: true)
        XCTAssertTrue(resolved)
        let result = await task.value
        XCTAssertEqual(result, .granted)
    }

    func testResolvePendingResolvesAllParkedPrompts() async {
        // Defensive n>1 case: with no ids to target, "resolve everything waiting"
        // is the only sane semantics — no zombie continuations left to time out.
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let t1 = Task { await coord.awaitDecision(id: "a") {} }
        let t2 = Task { await coord.awaitDecision(id: "b") {} }
        await yieldUntilParked()
        let resolved = coord.resolvePending(granted: false)
        XCTAssertTrue(resolved)
        let r1 = await t1.value
        let r2 = await t2.value
        XCTAssertFalse(r1.isGranted)
        XCTAssertFalse(r2.isGranted)
    }

    func testResolvePendingAfterResolveByIdIsNoOp() async {
        // A prompt already answered by id leaves nothing pending.
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "a") {} }
        await yieldUntilParked()
        coord.resolve(id: "a", granted: true)
        let result = await task.value
        XCTAssertEqual(result, .granted)
        XCTAssertFalse(coord.resolvePending(granted: false))
    }

    func testConcurrentResolvePendingResolvesEachOnce() async {
        // Two racing resolvePending calls must not double-resume a continuation
        // (that would crash) — the drain-under-lock lets exactly one see it.
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "a") {} }
        await yieldUntilParked()
        async let a = Task.detached { coord.resolvePending(granted: true) }.value
        async let b = Task.detached { coord.resolvePending(granted: true) }.value
        let (ra, rb) = await (a, b)
        XCTAssertNotEqual(ra, rb, "exactly one racing resolvePending should see the pending prompt")
        let result = await task.value
        XCTAssertEqual(result, .granted)
    }

    /// Sleep briefly so the awaiting task registers its continuation inside
    /// `withCheckedContinuation` before the test resolves it.
    private func yieldUntilParked() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
}

/// Runs the jobs of tasks that prefer it on one serial queue, at background
/// priority until `raisePriority()`. An unstructured `Task {}` started from such
/// a job does not inherit the preference, so it lands on the global pool at the
/// task's own priority.
@available(macOS 15, *)
private final class BackgroundTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "ConsentPromptCoordinatorTests.caller", qos: .background)
    private let qos = OSAllocatedUnfairLock<DispatchQoS>(initialState: .background)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async(qos: qos.withLock { $0 }, flags: .enforceQoS) {
            job.runSynchronously(on: executor)
        }
    }

    /// Later jobs run at high priority, and the empty block makes the serial
    /// queue drain what is already waiting at that priority too.
    func raisePriority() {
        qos.withLock { $0 = .userInitiated }
        queue.async(qos: .userInitiated, flags: .enforceQoS) {}
    }
}
