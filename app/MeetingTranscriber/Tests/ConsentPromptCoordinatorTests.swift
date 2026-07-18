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

    /// Sleep briefly so the awaiting task registers its continuation inside
    /// `withCheckedContinuation` before the test resolves it.
    private func yieldUntilParked() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
}
