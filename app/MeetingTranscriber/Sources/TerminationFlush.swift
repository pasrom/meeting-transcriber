// What AppKit waits for between a quit request and the process exit.
//
// `PipelineQueue.saveSnapshot()` hands the write to a detached worker, so a
// state transition reaches disk a few milliseconds after it happened in
// memory. Without a termination hook, a quit inside that gap exits with the
// snapshot still describing the moment before, and the restore on the next
// launch (and Retry, which reads the restored job) acts on that older state.
// The application delegate holds the quit open until the pending writes have
// landed, bounded so a write wedged in the rename syscall cannot turn a quit
// into a hang.
//
// It is also the one shutdown path. The menu's Quit only calls `terminate`;
// Cmd-Q, logout, shutdown and an AppleScript quit never went through the menu,
// so anything a quit owes has to happen here. First watching stops and an
// in-flight recording is stopped and enqueued, then the snapshot that enqueue
// produced is flushed. The other order would flush first and then enqueue a
// job whose snapshot write the exit cuts off.
//
// The in-flight pipeline stage is deliberately not waited for: a transcription
// or protocol call can run for minutes, and an interrupted job already resumes
// from what the snapshot recorded. Only the record itself is owed.
import AppKit
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Termination")

/// What a quit waits for. `AppState` is the production conformer; the
/// application delegate holds it once `MeetingTranscriberApp` has set it.
@MainActor
protocol AppTerminating: AnyObject {
    /// Whether a quit has anything to wait for. False lets it through at once.
    var hasWorkBeforeQuit: Bool { get }

    /// Stop watching and return once an in-flight recording has been stopped
    /// and enqueued. Runs before the flush, so the snapshot the enqueue
    /// produced is among those flushed.
    func finishRecordingBeforeQuit() async

    /// Return once every pending pipeline snapshot write has landed.
    func flushSnapshotsBeforeQuit() async

    /// Last synchronous cleanup, run right before the quit is let through.
    func tearDownBeforeExit()
}

/// The one thing the delegate needs from the application that asked to quit.
/// `NSApplication` has it already; tests pass a fake, because replying on the
/// real shared application would end the test process.
@MainActor
protocol TerminationReplying: AnyObject {
    func reply(toApplicationShouldTerminate shouldTerminate: Bool)
}

extension NSApplication: TerminationReplying {}

@MainActor
enum TerminationFlush {
    /// How long a quit waits for an in-flight recording to be stopped and
    /// enqueued: a manual start still in flight, then the recording's mix,
    /// which runs off the main thread and takes seconds for a long recording.
    /// A mix this cuts off is re-mixed by the next launch's crash recovery.
    ///
    /// The budget is a timer on the main actor, so it bounds only what leaves
    /// the main thread. Ending the capture session does not: the HAL and
    /// engine teardown at the start of `stopOffMain` runs on the main actor,
    /// as every stop does, because the capture objects serialize their device
    /// and restart callbacks on the main queue. A teardown that blocks holds
    /// the quit for as long as it blocks. The one wedge known there, a
    /// restart stuck inside the engine (issue #588), is skipped by the stop
    /// itself; no other has been measured.
    static let recordingBudget: Duration = .seconds(5)

    /// Long enough for any healthy snapshot write, short enough that a quit
    /// behind a wedged one still feels like a quit.
    static let flushBudget: Duration = .seconds(2)

    /// Run `operation` and return once it finishes or `budget` elapses,
    /// whichever comes first; true means it finished in time. The side that
    /// lost is cancelled.
    ///
    /// Not a task group: a group returns only after all of its children have,
    /// and awaiting another task's value does not end early on cancellation,
    /// so a flush wedged in the rename syscall would hold the group, and the
    /// quit, open for as long as it stayed wedged. Here the losing operation
    /// is cancelled and left behind; the process is about to exit anyway.
    static func run(within budget: Duration, _ operation: @escaping @MainActor () async -> Void) async -> Bool {
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.work = Task { @MainActor in
                await operation()
                race.finish(inTime: true)
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: budget)
                race.finish(inTime: false)
            }
        }
    }

    @MainActor
    private final class Race {
        var continuation: CheckedContinuation<Bool, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?

        func finish(inTime: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            work?.cancel()
            timer?.cancel()
            continuation.resume(returning: inTime)
        }
    }
}

/// How a quit request is answered. Pure, so every case is pinned without a
/// delegate, a sender or a clock.
enum QuitRequestAnswer: Equatable {
    /// Let the quit through now. `tearDown` says whether there is state to
    /// tear down first.
    case letThrough(tearDown: Bool)
    /// Hold the quit open and start the work it owes.
    case holdOpen
    /// A quit is already held open: answer this one the same way and start
    /// nothing, so there is never a second flush or a second reply. The
    /// reply that ends the first one ends the process.
    ///
    /// A guard, not a path known to be taken. Every quit reaches the delegate
    /// through AppKit's `terminate:` (the menu's Quit calls it too). Of a
    /// second AppleScript quit sent while the first was held open, two
    /// outcomes were measured, and neither came here: AppKit refused it itself
    /// ("Failed responder chain validation for terminate: action. Canceling
    /// termination.", the script got -128), or it queued the request and asked
    /// again only after the first reply had gone out (see `QuitPhase.replied`).
    /// Both ended in one exit. Whether a logout or a shutdown arriving during
    /// a held quit reaches the delegate is not measured.
    case joinPending

    static func decide(phase: QuitPhase, hasState: Bool, hasWork: Bool) -> Self {
        switch phase {
        case .holdingOpen:
            return .joinPending

        // The quit was granted and its work and teardown are done; a request
        // AppKit queued behind it is let through with nothing left to do,
        // rather than held open for a reply nothing would send.
        case .replied:
            return .letThrough(tearDown: false)

        case .idle:
            break
        }
        guard hasState else { return .letThrough(tearDown: false) }
        return hasWork ? .holdOpen : .letThrough(tearDown: true)
    }
}

/// Where the delegate is in answering quits.
enum QuitPhase: Equatable {
    /// No quit has been held open.
    case idle
    /// A quit is held open and its reply has not gone out yet.
    case holdingOpen
    /// The reply to a held quit has gone out. Measured live: a second
    /// AppleScript quit sent 4 ms after the first was asked about 9 ms after
    /// that reply.
    case replied
}

/// Routes AppKit's termination request, whichever path raised it (the menu's
/// Quit, Cmd-Q, logout, shutdown), through `AppTerminating`. Attached with
/// `@NSApplicationDelegateAdaptor`, so SwiftUI owns the one instance.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's state, handed over by `MeetingTranscriberApp.init`. That runs
    /// before the run loop starts, so no quit request can arrive before it.
    /// Static because SwiftUI constructs this delegate itself and the app
    /// cannot reach the instance from its `init`; handing it over from a
    /// view instead (the menu-bar label's `.task`, as it once was) left every
    /// quit before that view appeared, or without it, with nothing to finish.
    private(set) static var installed: (any AppTerminating)?

    static func install(_ termination: any AppTerminating) {
        installed = termination
    }

    /// Tests only: drop what `install` handed over.
    static func uninstallForTesting() {
        installed = nil
    }

    /// Who answers the quit: set directly by tests, otherwise what the app
    /// installed. Nil lets a quit through at once: there is nothing to flush.
    var termination: (any AppTerminating)? {
        get { injectedTermination ?? Self.installed }
        set { injectedTermination = newValue }
    }

    private var injectedTermination: (any AppTerminating)?

    var recordingBudget = TerminationFlush.recordingBudget
    var flushBudget = TerminationFlush.flushBudget

    /// Where a budget that ran out is reported. Tests capture it.
    var log: (String) -> Void = { logger.warning("\($0, privacy: .public)") }

    private var phase = QuitPhase.idle

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate(replyingTo: sender)
    }

    /// The decision behind `applicationShouldTerminate`, with the sender
    /// reduced to the one call it receives.
    func shouldTerminate(replyingTo sender: any TerminationReplying) -> NSApplication.TerminateReply {
        let termination = termination
        switch QuitRequestAnswer.decide(
            phase: phase,
            hasState: termination != nil,
            hasWork: termination?.hasWorkBeforeQuit ?? false,
        ) {
        case .joinPending:
            return .terminateLater

        case let .letThrough(tearDown):
            if tearDown { termination?.tearDownBeforeExit() }
            return .terminateNow

        case .holdOpen:
            break
        }
        guard let termination else { return .terminateNow }
        phase = .holdingOpen
        let recordingBudget = recordingBudget
        let flushBudget = flushBudget
        let log = log
        Task { @MainActor in
            // Each phase has its own budget, so a slow recording stop cannot
            // use up the time the flush after it needs.
            if await !TerminationFlush.run(within: recordingBudget, { await termination.finishRecordingBeforeQuit() }) {
                log("Quit: the recording budget (\(recordingBudget)) ran out; a mix it cut off is left to crash recovery")
            }
            let flushedInTime = await TerminationFlush.run(within: flushBudget) {
                await termination.flushSnapshotsBeforeQuit()
            }
            if !flushedInTime {
                log("Quit: the snapshot flush budget (\(flushBudget)) ran out")
            }
            // A mix the recording budget cut off goes on running, and its
            // enqueue can land in the hop between the flush and this line,
            // with that snapshot write still in flight at exit. Ask once more,
            // unless the first flush ran out of time: it is stuck on a write
            // that has not returned, and a second one would wait on the same.
            if flushedInTime, termination.hasWorkBeforeQuit,
               await !TerminationFlush.run(within: flushBudget, { await termination.flushSnapshotsBeforeQuit() }) {
                log("Quit: the second snapshot flush budget (\(flushBudget)) ran out")
            }
            // Logged lines first: the teardown stops the streamer that carries
            // them to the persistent log.
            termination.tearDownBeforeExit()
            phase = .replied
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
