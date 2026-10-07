@testable import MeetingTranscriber
import XCTest

/// The quit's reply: what happens in the moment just after the flush, and
/// what is logged when a budget runs out.
@MainActor
final class QuitReplyTests: XCTestCase {
    private final class FakeTermination: AppTerminating {
        var hasWorkBeforeQuit: Bool
        var steps: [String] = []
        var finishRecording: @MainActor () async -> Void = {}
        var flush: @MainActor () async -> Void = {}

        init(hasWorkBeforeQuit: Bool) {
            self.hasWorkBeforeQuit = hasWorkBeforeQuit
        }

        func finishRecordingBeforeQuit() async {
            steps.append("finish recording")
            await finishRecording()
        }

        func flushSnapshotsBeforeQuit() async {
            steps.append("flush")
            await flush()
        }

        func tearDownBeforeExit() {
            steps.append("tear down")
        }
    }

    private func waitForReply(_ sender: QuitTestSender) async {
        let replied = expectation(description: "reply")
        replied.assertForOverFulfill = false
        sender.onReply = { replied.fulfill() }
        if !sender.replies.isEmpty { replied.fulfill() }
        await fulfillment(of: [replied], timeout: 5)
    }

    // MARK: - The moment after the flush

    /// A recording whose mix outran its budget is enqueued whenever the mix
    /// ends, and that can be in the hop between the flush finishing and the
    /// reply going out. Its snapshot write would then be in flight at exit.
    /// Before replying, the delegate asks once more and flushes once more.
    func testAWriteThatStartsJustAfterTheFlushIsFlushedBeforeTheReply() async {
        let delegate = AppDelegate()
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        var flushes = 0
        termination.flush = {
            flushes += 1
            guard flushes == 1 else {
                termination.hasWorkBeforeQuit = false
                return
            }
            termination.hasWorkBeforeQuit = false
            // The late enqueue: lands on the main actor right after this
            // flush has reported done.
            Task { @MainActor in termination.hasWorkBeforeQuit = true }
        }
        delegate.termination = termination
        let sender = QuitTestSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertEqual(flushes, 2, "the write that started after the flush was not waited for")
        XCTAssertEqual(termination.steps.last, "tear down")
    }

    /// A flush that ran out of time is stuck on a write that has not
    /// returned, and asking again only waits on the same write. A wedged
    /// rename (the macOS 26 rename deadlock the writer is isolated for) would
    /// otherwise cost every quit both flush budgets.
    func testAFlushThatRanOutOfTimeIsNotTriedAgain() async {
        let delegate = AppDelegate()
        delegate.flushBudget = .milliseconds(100)
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        termination.flush = { try? await Task.sleep(for: .seconds(30)) }
        delegate.termination = termination
        let sender = QuitTestSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertEqual(termination.steps.filter { $0 == "flush" }.count, 1, "\(termination.steps)")
    }

    // MARK: - What a budget that runs out leaves in the log

    /// Each budget that runs out says so, before the teardown stops the log
    /// streamer that would carry the line to disk.
    func testEachBudgetThatRunsOutIsLoggedBeforeTheTeardown() async {
        let delegate = AppDelegate()
        delegate.recordingBudget = .milliseconds(50)
        delegate.flushBudget = .milliseconds(50)
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        termination.finishRecording = { try? await Task.sleep(for: .seconds(30)) }
        termination.flush = {
            // Nothing new pending afterwards, so no second flush runs.
            termination.hasWorkBeforeQuit = false
            try? await Task.sleep(for: .seconds(30))
        }
        delegate.termination = termination
        var lines: [String] = []
        delegate.log = { line in
            lines.append(line)
            termination.steps.append("log")
        }
        let sender = QuitTestSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertEqual(lines.count, 2, "one line per budget that ran out: \(lines)")
        XCTAssertEqual(lines.first?.contains("recording"), true, "\(lines)")
        XCTAssertEqual(lines.last?.contains("flush"), true, "\(lines)")
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
        let sender = QuitTestSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertEqual(lines, [])
    }
}
