@testable import MeetingTranscriber
import XCTest

/// The quit's reply: what is logged when a budget runs out.
@MainActor
final class QuitReplyTests: XCTestCase {
    private final class FakeSender: TerminationReplying {
        var replies: [Bool] = []
        var onReply: (() -> Void)?

        func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
            replies.append(shouldTerminate)
            onReply?()
        }
    }

    private final class FakeTermination: AppTerminating {
        var hasWorkBeforeQuit: Bool
        var steps: [String] = []
        var flush: @MainActor () async -> Void = {}

        init(hasWorkBeforeQuit: Bool) {
            self.hasWorkBeforeQuit = hasWorkBeforeQuit
        }

        func flushSnapshotsBeforeQuit() async {
            steps.append("flush")
            await flush()
        }

        func tearDownBeforeExit() {
            steps.append("tear down")
        }
    }

    private func waitForReply(_ sender: FakeSender) async {
        let replied = expectation(description: "reply")
        replied.assertForOverFulfill = false
        sender.onReply = { replied.fulfill() }
        if !sender.replies.isEmpty { replied.fulfill() }
        await fulfillment(of: [replied], timeout: 5)
    }

    // MARK: - What a budget that runs out leaves in the log

    /// A flush cut off by its budget says so, before the teardown stops the
    /// log streamer that would carry the line to disk: otherwise the next
    /// launch restores an older snapshot and nobody can tell why.
    func testAFlushBudgetThatRunsOutIsLoggedBeforeTheTeardown() async {
        let delegate = AppDelegate()
        delegate.flushBudget = .milliseconds(50)
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        termination.flush = { try? await Task.sleep(for: .seconds(30)) }
        delegate.termination = termination
        var lines: [String] = []
        delegate.log = { line in
            lines.append(line)
            termination.steps.append("log")
        }
        let sender = FakeSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertEqual(lines.count, 1, "one line per budget that ran out: \(lines)")
        XCTAssertEqual(lines.first?.contains("flush"), true, "\(lines)")
        let teardown = termination.steps.lastIndex(of: "tear down")
        let lastLog = termination.steps.lastIndex(of: "log")
        XCTAssertNotNil(teardown)
        XCTAssertLessThan(lastLog ?? .max, teardown ?? .min, "logged after the streamer was stopped")
    }

    func testABudgetThatHoldsLogsNothing() async {
        let delegate = AppDelegate()
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        delegate.termination = termination
        var lines: [String] = []
        delegate.log = { lines.append($0) }
        let sender = FakeSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertEqual(lines, [])
    }
}
