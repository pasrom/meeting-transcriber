@testable import MeetingTranscriber
import XCTest

final class ConsentPromptCoordinatorTests: XCTestCase {
    /// A timeout sleep that effectively never returns, so the timeout can't win
    /// and the test drives resolution explicitly.
    private let neverSleep: @Sendable (TimeInterval) async -> Void = { _ in
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func testResolvesToGrantedAnswer() async {
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "a") {} }
        await yieldUntilParked()
        coord.resolve(id: "a", granted: true)
        let result = await task.value
        XCTAssertTrue(result)
    }

    func testResolvesToDeniedAnswer() async {
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "b") {} }
        await yieldUntilParked()
        coord.resolve(id: "b", granted: false)
        let result = await task.value
        XCTAssertFalse(result)
    }

    func testUnansweredPromptTimesOutToDeny() async {
        // A short real timeout: an unanswered prompt resolves to "don't record".
        let coord = ConsentPromptCoordinator(timeout: 0.02)
        let result = await coord.awaitDecision(id: "c") {}
        XCTAssertFalse(result)
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
        XCTAssertTrue(result)
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
        XCTAssertTrue(result)
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
        XCTAssertFalse(r1)
        XCTAssertFalse(r2)
    }

    func testResolvePendingAfterResolveByIdIsNoOp() async {
        // A prompt already answered by id leaves nothing pending.
        let coord = ConsentPromptCoordinator(timeout: 60, sleep: neverSleep)
        let task = Task { await coord.awaitDecision(id: "a") {} }
        await yieldUntilParked()
        coord.resolve(id: "a", granted: true)
        let result = await task.value
        XCTAssertTrue(result)
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
        XCTAssertTrue(result)
    }

    /// Sleep briefly so the awaiting task registers its continuation inside
    /// `withCheckedContinuation` before the test resolves it.
    private func yieldUntilParked() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
}
