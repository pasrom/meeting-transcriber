import AppKit
@testable import MeetingTranscriber
import XCTest

/// What AppKit waits for between a quit request and the process exit.
///
/// The delegate is driven through `shouldTerminate(replyingTo:)` with a fake
/// sender, because replying on the real shared application would end the test
/// process. What only a live quit can show: that SwiftUI routes
/// `applicationShouldTerminate` to the adaptor's delegate at all, and whether
/// AppKit asks again while a quit is held open.
/// `testTheAppDeclaresTheDelegateAndHandsItTheStateInInit` pins the source
/// lines that wiring depends on, nothing more.
@MainActor
final class TerminationFlushTests: XCTestCase {
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
        var flushes = 0
        var steps: [String] = []
        var flush: @MainActor () async -> Void = {}

        init(hasWorkBeforeQuit: Bool) {
            self.hasWorkBeforeQuit = hasWorkBeforeQuit
        }

        func flushSnapshotsBeforeQuit() async {
            flushes += 1
            steps.append("flush")
            await flush()
            // A flush that finished leaves nothing to wait for, as the real
            // one does; one cut off by its budget never gets here.
            hasWorkBeforeQuit = false
        }

        func tearDownBeforeExit() {
            steps.append("tear down")
        }
    }

    private func makeJob(title: String) -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }

    /// A queue whose writer takes long enough that the write cannot have
    /// landed by accident before a quit is answered.
    private func makeSlowSnapshotQueue(in dir: URL) -> PipelineQueue {
        // swiftlint:disable:next trailing_closure
        PipelineQueue(logDir: dir, snapshotWriter: { jobs, url in
            Thread.sleep(forTimeInterval: 0.3)
            try PipelineSnapshot.save(jobs, to: url)
        })
    }

    private func waitForReply(_ sender: FakeSender, timeout: TimeInterval = 5) async {
        let replied = expectation(description: "reply")
        replied.assertForOverFulfill = false
        let observe = sender.onReply
        sender.onReply = {
            observe?()
            replied.fulfill()
        }
        if !sender.replies.isEmpty { replied.fulfill() }
        await fulfillment(of: [replied], timeout: timeout)
        sender.onReply = observe
    }

    // MARK: - The bounded race

    func testRunReturnsAsSoonAsTheOperationFinishes() async {
        let start = ContinuousClock.now
        let inTime = await TerminationFlush.run(within: .seconds(30)) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(inTime)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "the finished operation waited for the timer")
    }

    func testRunCutsOffAWedgedOperationAndCancelsIt() async throws {
        var sawCancellation = false
        let start = ContinuousClock.now
        let inTime = await TerminationFlush.run(within: .milliseconds(100)) {
            try? await Task.sleep(for: .seconds(30))
            sawCancellation = Task.isCancelled
        }
        XCTAssertFalse(inTime)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        // The cancelled operation wakes and records it shortly after.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sawCancellation, "the operation that lost the race was not cancelled")
    }

    // `AppDelegate.install` is process-wide, so neither a test before this
    // one nor this one may leave state installed for the next.
    override func setUp() async throws {
        try await super.setUp()
        AppDelegate.uninstallForTesting()
    }

    override func tearDown() async throws {
        AppDelegate.uninstallForTesting()
        try await super.tearDown()
    }

    // MARK: - The answer

    func testTheAnswerToEachQuitRequest() {
        XCTAssertEqual(QuitRequestAnswer.decide(phase: .idle, hasState: false, hasWork: false), .letThrough(tearDown: false))
        XCTAssertEqual(QuitRequestAnswer.decide(phase: .idle, hasState: true, hasWork: false), .letThrough(tearDown: true))
        XCTAssertEqual(QuitRequestAnswer.decide(phase: .idle, hasState: true, hasWork: true), .holdOpen)
        // Whatever else holds: a request while one is held open is answered
        // like the one being held, and one after the reply went out is let
        // through with nothing left to do.
        for hasState in [false, true] {
            for hasWork in [false, true] {
                XCTAssertEqual(
                    QuitRequestAnswer.decide(phase: .holdingOpen, hasState: hasState, hasWork: hasWork), .joinPending,
                )
                XCTAssertEqual(
                    QuitRequestAnswer.decide(phase: .replied, hasState: hasState, hasWork: hasWork),
                    .letThrough(tearDown: false),
                )
            }
        }
    }

    // MARK: - The delegate

    /// SwiftUI builds the delegate itself, so the state cannot be handed to
    /// that instance; the app installs it for whichever instance asks.
    func testADelegateNobodyConfiguredAnswersWithTheInstalledState() async {
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        AppDelegate.install(termination)
        let delegate = AppDelegate()
        let sender = FakeSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertEqual(termination.steps, ["flush", "tear down"])
    }

    func testWithoutStateTheQuitGoesThroughAtOnce() {
        let delegate = AppDelegate()
        let sender = FakeSender()
        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateNow)
        XCTAssertEqual(sender.replies, [], "terminateNow must not also send a deferred reply")
    }

    func testNothingPendingTerminatesNowWithoutFlushing() {
        let delegate = AppDelegate()
        let termination = FakeTermination(hasWorkBeforeQuit: false)
        delegate.termination = termination
        let sender = FakeSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateNow)
        XCTAssertEqual(termination.flushes, 0)
        XCTAssertEqual(sender.replies, [])
        XCTAssertEqual(termination.steps, ["tear down"], "a quit let through at once skipped the teardown")
    }

    /// The streamer used to be stopped from a `willTerminateNotification`
    /// observer through a `Task` hop that `exit` always beat. Now the delegate
    /// stops it synchronously before the quit is let through.
    func testTearingDownStopsThePersistentLogStreamer() throws {
        #if APPSTORE
            throw XCTSkip("the App Store build has no persistent log streamer")
        #else
            let state = try makeIsolatedAppState()
            try XCTSkipIf(state.persistentLogStreamer == nil, "the streamer did not start in this environment")

            state.tearDownBeforeExit()

            XCTAssertNil(state.persistentLogStreamer)
        #endif
    }

    func testTheReplyWaitsForTheFlush() async {
        let delegate = AppDelegate()
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        var flushed = false
        termination.flush = {
            try? await Task.sleep(for: .milliseconds(100))
            flushed = true
        }
        delegate.termination = termination
        let sender = FakeSender()
        var flushedAtReply = false
        sender.onReply = { flushedAtReply = flushed }

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertTrue(flushedAtReply, "the reply went out before the flush had finished")
        XCTAssertEqual(sender.replies, [true])
    }

    func testAWedgedFlushIsCutOffByTheBudgetAndRepliesOnce() async throws {
        let delegate = AppDelegate()
        delegate.flushBudget = .milliseconds(100)
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        termination.flush = { try? await Task.sleep(for: .seconds(30)) }
        delegate.termination = termination
        let sender = FakeSender()
        let start = ContinuousClock.now

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender)

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sender.replies, [true])
    }

    /// If AppKit asks again while a quit is held open, the delegate starts no
    /// second flush and sends no second reply. This pins the guard, not a
    /// measured path: in live runs a second AppleScript quit was refused by
    /// AppKit itself or asked about only after the first reply (see
    /// `QuitRequestAnswer.joinPending`).
    func testASecondRequestWhileTheFirstIsHeldOpenStartsNothing() async throws {
        let delegate = AppDelegate()
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        termination.flush = { try? await Task.sleep(for: .milliseconds(200)) }
        delegate.termination = termination
        let first = FakeSender()
        let second = FakeSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: first), .terminateLater)
        XCTAssertEqual(
            delegate.shouldTerminate(replyingTo: second), .terminateLater,
            "a second request is answered like the one being held",
        )
        await waitForReply(first)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(termination.flushes, 1)
        XCTAssertEqual(first.replies, [true])
        XCTAssertEqual(second.replies, [])
    }

    /// Measured live: a second AppleScript quit that arrived while the first
    /// was held open was queued by AppKit and handed to the delegate after the
    /// first reply had gone out. That request is let through at once: the
    /// work is done, so it starts no second flush, and it is not left
    /// waiting for a reply nothing sends.
    func testARequestAfterTheFirstReplyIsLetThroughWithoutASecondFlush() async throws {
        let delegate = AppDelegate()
        let termination = FakeTermination(hasWorkBeforeQuit: true)
        delegate.termination = termination
        let first = FakeSender()
        let second = FakeSender()

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: first), .terminateLater)
        await waitForReply(first)
        // The real flush leaves nothing owed; this one must not be what
        // decides the answer.
        termination.hasWorkBeforeQuit = true

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: second), .terminateNow)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(termination.flushes, 1)
        XCTAssertEqual(termination.steps.filter { $0 == "tear down" }.count, 1)
        XCTAssertEqual(first.replies, [true])
        XCTAssertEqual(second.replies, [], "terminateNow must not also send a deferred reply")
    }

    // MARK: - The production state

    /// The case the issue describes: a state transition whose snapshot write
    /// is still in flight when the user quits, through the delegate and
    /// `AppState` as production wires them.
    func testTheSnapshotIsOnDiskWhenTheQuitIsAnswered() async throws {
        let dir = try makeTempDirectory(prefix: "termination_flush")
        let state = try makeIsolatedAppState(initialQueue: makeSlowSnapshotQueue(in: dir))
        let job = makeJob(title: "Quit Mid-Write")
        state.pipeline.queue.enqueue(job)
        state.pipeline.queue.updateJobState(id: job.id, to: .transcribing)

        let delegate = AppDelegate()
        delegate.termination = state
        let sender = FakeSender()
        var onDiskAtReply: [PipelineJob] = []
        sender.onReply = { onDiskAtReply = (try? PipelineSnapshot.load(from: dir)) ?? [] }

        XCTAssertEqual(delegate.shouldTerminate(replyingTo: sender), .terminateLater)
        await waitForReply(sender, timeout: 10)

        XCTAssertEqual(onDiskAtReply.map(\.id), [job.id], "the quit was answered before the snapshot was written")
        XCTAssertEqual(onDiskAtReply.first?.state, .transcribing)
    }

    #if DEBUG
        /// `rebuild()` replaces the queue, and the replaced one may still be
        /// writing. Its write is owed too, and it must not be dropped because
        /// the replaced queue is released. Both write the same file, as every
        /// queue the controller builds does. The swap goes through
        /// `installQueueForTesting`, which exists only in debug builds.
        func testAReplacedQueuesPendingWriteIsWaitedForAndStillLands() async throws {
            let dir = try makeTempDirectory(prefix: "termination_flush_replaced")
            let controller = try makeIsolatedPipelineController(initialQueue: makeSlowSnapshotQueue(in: dir))
            let first = makeJob(title: "Before Rebuild")
            controller.queue.enqueue(first)
            // Queued behind the write in flight, so only a writer that keeps
            // running after the swap can write it.
            controller.queue.updateJobState(id: first.id, to: .transcribing)

            controller.installQueueForTesting(PipelineQueue(logDir: dir))

            XCTAssertTrue(controller.hasPendingSnapshotWrites, "the replaced queue's write in flight was not counted")
            await controller.awaitSnapshotFlushes()

            let jobs = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
            XCTAssertEqual(jobs.map(\.id), [first.id])
            XCTAssertEqual(jobs.first?.state, .transcribing, "the replaced queue's last state change was never written")
            XCTAssertFalse(controller.hasPendingSnapshotWrites)
        }
    #endif

    func testAnIdleAppStateHasNothingToWaitFor() throws {
        let state = try makeIsolatedAppState(
            initialQueue: PipelineQueue(logDir: makeTempDirectory(prefix: "termination_flush_idle")),
        )
        XCTAssertFalse(state.hasWorkBeforeQuit)
    }

    // MARK: - Wiring

    /// A pin on the declaration, not proof that SwiftUI calls the delegate:
    /// deleting the adaptor or the hand-over otherwise leaves every test in
    /// this file green, since they build the delegate themselves.
    ///
    /// The hand-over has to happen in the app's `init`, which runs before the
    /// run loop and so before any quit request can arrive. It used to happen
    /// in the menu-bar label's `.task`, which runs only once that view has
    /// appeared: a quit before then, or with the menu-bar item hidden, found
    /// no state and was let through without finishing anything.
    func testTheAppDeclaresTheDelegateAndHandsItTheStateInInit() throws {
        let text = try String(contentsOf: Self.appSource(), encoding: .utf8)
        XCTAssertTrue(text.contains("@NSApplicationDelegateAdaptor(AppDelegate.self)"))
        let initBody = try XCTUnwrap(
            text.components(separatedBy: "    init() {").dropFirst().first?
                .components(separatedBy: "\n    }\n").first,
            "no init() in the app source",
        )
        XCTAssertTrue(initBody.contains("AppDelegate.install("), "the state is not handed over in init")
        XCTAssertFalse(
            text.contains("appDelegate.termination = appState"),
            "the state is still handed over from a view's .task",
        )
    }

    /// A test method with parameters is not discovered by XCTest, so the
    /// `#filePath` default lives here.
    private static func appSource(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingTranscriberApp.swift")
    }
}
