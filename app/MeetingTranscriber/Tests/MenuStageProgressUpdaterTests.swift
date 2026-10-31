import AppKit
@testable import MeetingTranscriber
import Observation
import XCTest

@MainActor
final class MenuStageProgressUpdaterTests: XCTestCase {
    func testStageTransitionsUpdateExistingProgressItemAndKeepCancelAction() throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_stage_test")
        let queue = PipelineQueue(logDir: dir)
        let job = PipelineJob(
            meetingTitle: "Sprint", appName: "Zoom",
            mixPath: dir.appendingPathComponent("mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .transcribing)

        let menu = NSMenu()
        let title = NSMenuItem(title: job.meetingTitle, action: nil, keyEquivalent: "")
        title.isEnabled = false
        let progress = NSMenuItem(title: JobState.transcribing.label, action: nil, keyEquivalent: "")
        progress.isEnabled = false
        let cancelTarget = MenuProgressCancelTarget(queue: queue, jobID: job.id)
        let cancelAction = #selector(MenuProgressCancelTarget.cancel(_:))
        let cancel = NSMenuItem(title: "Cancel", action: cancelAction, keyEquivalent: "")
        cancel.target = cancelTarget
        menu.addItem(title)
        menu.addItem(progress)
        menu.addItem(cancel)

        let updater = MenuStageProgressUpdater()
        updater.refresh(menu: menu, queue: queue)
        for state in [JobState.diarizing, .generatingProtocol] {
            queue.updateJobState(id: job.id, to: state)
            updater.refresh(menu: menu, queue: queue)

            let activeJob = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
            XCTAssertEqual(progress.title, MenuStageProgressUpdater.progressText(job: activeJob, queue: queue))
            XCTAssertEqual(menu.items.count, 3)
            XCTAssertIdentical(menu.items[0], title)
            XCTAssertIdentical(menu.items[1], progress)
            XCTAssertIdentical(menu.items[2], cancel)
            XCTAssertFalse(progress.isEnabled)
            XCTAssertTrue(cancel.isEnabled)
            XCTAssertEqual(cancel.action, cancelAction)
            XCTAssertIdentical(cancel.target, cancelTarget)
        }

        _ = NSApplication.shared
        menu.performActionForItem(at: 2)
        XCTAssertEqual(cancelTarget.callCount, 1)
        XCTAssertFalse(queue.jobs.contains { $0.id == job.id })
    }

    func testProgressRefreshPreservesMenuItemsAndCancelAction() async throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_updater_test")
        let queue = PipelineQueue(logDir: dir)
        let job = PipelineJob(
            meetingTitle: "Sprint", appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .diarizing)
        let activeJob = try XCTUnwrap(queue.jobs.first { $0.id == job.id })

        let menu = NSMenu()
        let title = NSMenuItem(title: job.meetingTitle, action: nil, keyEquivalent: "")
        title.isEnabled = false
        let progress = NSMenuItem(title: activeJob.state.label, action: nil, keyEquivalent: "")
        progress.isEnabled = false
        let cancelTarget = MenuProgressCancelTarget(queue: queue, jobID: job.id)
        let cancelAction = #selector(MenuProgressCancelTarget.cancel(_:))
        let cancel = NSMenuItem(title: "Cancel", action: cancelAction, keyEquivalent: "")
        cancel.target = cancelTarget
        menu.addItem(title)
        menu.addItem(progress)
        menu.addItem(cancel)

        let updater = MenuStageProgressUpdater()
        updater.refresh(menu: menu, queue: queue)
        let initialProgress = progress.title
        updater.observe { queue }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) }
        try await Task.sleep(for: .milliseconds(20))
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        await waitForTitleChange(progress, from: initialProgress)

        XCTAssertNotEqual(progress.title, initialProgress)
        XCTAssertTrue(progress.title.hasPrefix(activeJob.state.label))
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertIdentical(menu.items[0], title)
        XCTAssertIdentical(menu.items[1], progress)
        XCTAssertIdentical(menu.items[2], cancel)
        XCTAssertFalse(title.isEnabled)
        XCTAssertFalse(progress.isEnabled)
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertEqual(cancel.action, cancelAction)
        XCTAssertIdentical(cancel.target, cancelTarget)

        _ = NSApplication.shared
        menu.performActionForItem(at: 2)
        XCTAssertEqual(cancelTarget.callCount, 1)
        XCTAssertFalse(queue.jobs.contains { $0.id == job.id })
    }

    func testOnlyMatchingMenuEndFlushesExpiredCompletedJob() async throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_expiry_test")
        let queue = PipelineQueue(logDir: dir, completedJobLifetime: 0.2)
        var job = PipelineJob(
            meetingTitle: "Sprint", appName: "Zoom",
            mixPath: dir.appendingPathComponent("mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.beginNotionExport(speakerNames: [])
        job.finishNotionExport(succeeded: true)
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        let trackedMenu = NSMenu()
        let unrelatedMenu = NSMenu()
        let updater = MenuStageProgressUpdater()
        updater.observe { queue }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: trackedMenu)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(queue.completedJobs.map(\.id), [job.id])

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: unrelatedMenu)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(queue.completedJobs.map(\.id), [job.id])

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: trackedMenu)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(queue.completedJobs.isEmpty)
    }

    func testExpiredJobWithoutAnExportIsRemovedWhileAMenuIsOpen() async throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_plain_expiry_test")
        let queue = PipelineQueue(logDir: dir, completedJobLifetime: 0.2)
        let job = PipelineJob(
            meetingTitle: "Sprint", appName: "Zoom",
            mixPath: dir.appendingPathComponent("mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        let trackedMenu = NSMenu()
        let updater = MenuStageProgressUpdater()
        updater.observe { queue }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: trackedMenu)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(queue.completedJobs.isEmpty)

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: trackedMenu)
    }

    /// `elapsedSeconds` must not register a dependency on the stage-start
    /// bookkeeping: that dictionary is rewritten on every stage transition, and
    /// a SwiftUI body that read it would be rebuilt while the menu is open.
    /// Waiting alone cannot pin that (nothing is written meanwhile), so a
    /// second job's stage change is the write the tracking must not notice.
    func testReadingElapsedTimeDoesNotObserveStageTransitions() throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_observation_test")
        let queue = PipelineQueue(logDir: dir)
        let first = PipelineJob(
            meetingTitle: "First", appName: "Zoom",
            mixPath: dir.appendingPathComponent("first.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let second = PipelineJob(
            meetingTitle: "Second", appName: "Zoom",
            mixPath: dir.appendingPathComponent("second.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(first)
        queue.enqueue(second)
        queue.updateJobState(id: first.id, to: .diarizing)

        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = queue.elapsedSeconds(forJobID: first.id)
        } onChange: {
            invalidated.raise()
        }
        queue.updateJobState(id: second.id, to: .transcribing)

        XCTAssertFalse(invalidated.isRaised, "A stage change must not rebuild a menu that only reads elapsed time")
        let start = ContinuousClock.now
        XCTAssertGreaterThan(
            queue.elapsedSeconds(forJobID: first.id, at: start + .seconds(5)),
            queue.elapsedSeconds(forJobID: first.id, at: start) + 4,
        )
    }

    /// Native menu tracking runs the main run loop in event-tracking mode. A
    /// timer added in `.default` mode would stand still there, which is the
    /// whole reason the updater exists, so the ticks must keep landing while
    /// only that mode is serviced.
    func testTimerKeepsTickingWhileTheMainLoopRunsInEventTrackingMode() async throws {
        // AppKit is what makes event-tracking mode one of the main loop's common
        // modes, so without an application this test would measure a loop the
        // running app never has (alone it failed, after another test touched it
        // it passed).
        _ = NSApplication.shared
        let dir = try makeTempDirectory(prefix: "menu_progress_tracking_mode_test")
        let queue = PipelineQueue(logDir: dir)
        let job = PipelineJob(
            meetingTitle: "Sprint", appName: "Zoom",
            mixPath: dir.appendingPathComponent("mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .diarizing)
        let menu = Self.menu(for: [job], in: queue)
        let progress = menu.items[1]
        let updater = MenuStageProgressUpdater()
        updater.observe { queue }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) }
        await waitForTitleChange(progress, from: JobState.diarizing.label)
        let settled = progress.title

        let afterSpin = await Self.titleAfterSpinningMainLoopInEventTrackingMode(of: progress, whileEqualTo: settled)

        XCTAssertNotEqual(afterSpin, settled, "No tick landed while only event-tracking mode ran")
    }

    /// Spins the main loop in event-tracking mode from a run-loop callback, the
    /// way AppKit enters menu tracking. Not from the test's own main-actor job:
    /// a nested loop inside an actor job holds the actor, so the updater's
    /// `Task { @MainActor }` hops could never run. And not from a libdispatch
    /// main-queue block either: libdispatch does not drain the main queue again
    /// from inside one of its own blocks, so the same hops would starve.
    /// The title is read before the callback returns: once the loop is back in
    /// default mode an overdue default-mode timer would fire at once and make a
    /// timer that stood still during tracking look as if it had ticked.
    /// It leaves as soon as the title moves, and waits up to `seconds` for it
    /// to do so, so a loaded runner gets time and a timer that never fires costs
    /// the full wait only when the test is about to fail.
    private static func titleAfterSpinningMainLoopInEventTrackingMode(
        of item: NSMenuItem, whileEqualTo settled: String, upTo seconds: TimeInterval = 6,
    ) async -> String {
        let box = MenuItemBox(item: item)
        return await withCheckedContinuation { continuation in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                // `run` returns after one handled source, or at once when the
                // mode has none, so it is driven until the deadline.
                let deadline = Date(timeIntervalSinceNow: seconds)
                while Date() < deadline, MainActor.assumeIsolated({ box.item.title }) == settled {
                    if !RunLoop.main.run(mode: .eventTracking, before: deadline) {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                continuation.resume(returning: MainActor.assumeIsolated { box.item.title })
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    func testEqualTitlesEachRowShowsItsOwnJobsStage() throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_equal_titles_test")
        let queue = PipelineQueue(logDir: dir)
        let jobs = ["a", "b"].map { name in
            PipelineJob(
                meetingTitle: "Zoom Meeting", appName: "Zoom",
                mixPath: dir.appendingPathComponent("\(name).wav"),
                appPath: nil, micPath: nil, micDelay: 0,
            )
        }
        jobs.forEach { queue.enqueue($0) }
        queue.updateJobState(id: jobs[0].id, to: .transcribing)
        queue.updateJobState(id: jobs[1].id, to: .diarizing)
        let menu = Self.menu(for: jobs, in: queue)

        MenuStageProgressUpdater().refresh(menu: menu, queue: queue)

        let progressTitles = menu.items.map(\.title).filter { $0.contains("...") && $0 != "Waiting..." }
        XCTAssertEqual(progressTitles.count, 2)
        XCTAssertTrue(progressTitles[0].hasPrefix("Transcribing"), progressTitles[0])
        XCTAssertTrue(progressTitles[1].hasPrefix("Diarizing"), progressTitles[1])
    }

    /// A meeting called like its own action row: "Cancel" is both the title of a
    /// waiting job and the label of that job's enabled Cancel action. The next
    /// job's progress row must still be found, so the walk may not take the
    /// action row for the next job's title.
    func testAJobTitledLikeItsOwnActionRowDoesNotHideTheNextJobsProgress() throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_lookalike_titles_test")
        let queue = PipelineQueue(logDir: dir)
        let waiting = PipelineJob(
            meetingTitle: "Cancel", appName: "Zoom",
            mixPath: dir.appendingPathComponent("waiting.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let active = PipelineJob(
            meetingTitle: "Cancel", appName: "Zoom",
            mixPath: dir.appendingPathComponent("active.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(waiting)
        queue.enqueue(active)
        queue.updateJobState(id: active.id, to: .diarizing)
        let menu = Self.menu(for: [waiting, active], in: queue)

        MenuStageProgressUpdater().refresh(menu: menu, queue: queue)

        XCTAssertEqual(menu.items[1].title, JobState.waiting.label, "The waiting job's row was rewritten")
        XCTAssertTrue(menu.items[5].title.hasPrefix("Diarizing... "), menu.items[5].title)
        XCTAssertEqual(menu.items[4].title, "Cancel")
    }

    /// The running meeting is listed above the queue. When it shares a job's
    /// auto-title, the walk must not anchor on it: the job's own row would never
    /// be updated and the meeting's detail line would be taken for its state.
    func testARunningMeetingWithTheSameTitleAboveTheQueueIsNotTakenForTheJob() throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_rows_above_test")
        let queue = PipelineQueue(logDir: dir)
        let job = PipelineJob(
            meetingTitle: "Zoom Meeting", appName: "Zoom",
            mixPath: dir.appendingPathComponent("a.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .diarizing)

        func disabledRow(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        // Whatever heading the menu still shows when the tick lands.
        for header in QueueHeader.all {
            let meetingTitle = disabledRow("Zoom Meeting")
            let meetingDetail = disabledRow("Transcribing... 9:99")
            let heading = disabledRow(header.title)
            let menu = Self.menu(for: [job], in: queue, above: [meetingTitle, meetingDetail, .separator(), heading])

            MenuStageProgressUpdater().refresh(menu: menu, queue: queue)

            XCTAssertEqual(meetingDetail.title, "Transcribing... 9:99", "A row above the queue was rewritten (\(header.title))")
            let stateRow = try XCTUnwrap(menu.items.last { $0.title.hasPrefix("Diarizing") })
            XCTAssertTrue(stateRow.title.hasPrefix("Diarizing... "), "\(header.title): \(stateRow.title)")
        }
    }

    /// A job called like a queue heading ("Queue", "Processing") comes after the
    /// real heading. Taking it for the heading would start the walk behind the
    /// jobs listed before it and freeze their progress text.
    func testAJobTitledLikeAQueueHeadingDoesNotMoveTheWalkPastEarlierJobs() throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_heading_title_test")
        let queue = PipelineQueue(logDir: dir)
        let first = PipelineJob(
            meetingTitle: "Zoom Meeting", appName: "Zoom",
            mixPath: dir.appendingPathComponent("first.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let second = PipelineJob(
            meetingTitle: QueueHeader.queue.title, appName: "Zoom",
            mixPath: dir.appendingPathComponent("second.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(first)
        queue.enqueue(second)
        queue.updateJobState(id: first.id, to: .diarizing)
        queue.updateJobState(id: second.id, to: .transcribing)
        let heading = NSMenuItem(title: QueueHeader.processing.title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        let menu = Self.menu(for: [first, second], in: queue, above: [heading])

        MenuStageProgressUpdater().refresh(menu: menu, queue: queue)

        let progress = menu.items.map(\.title).filter { $0.hasPrefix("Diarizing... ") || $0.hasPrefix("Transcribing... ") }
        XCTAssertEqual(progress.count, 2, "\(progress)")
        guard progress.count == 2 else { return }
        XCTAssertTrue(progress[0].hasPrefix("Diarizing... "), progress[0])
        XCTAssertTrue(progress[1].hasPrefix("Transcribing... "), progress[1])
    }

    /// The rows SwiftUI emits for each job: a disabled title, a disabled state
    /// row, an enabled Cancel, and a separator between jobs.
    private static func menu(
        for jobs: [PipelineJob], in queue: PipelineQueue, above: [NSMenuItem] = [],
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        above.forEach(menu.addItem)
        let target = MenuProgressCancelTarget(queue: queue, jobID: UUID())
        for (index, job) in jobs.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let title = NSMenuItem(title: job.meetingTitle, action: nil, keyEquivalent: "")
            title.isEnabled = false
            let state = NSMenuItem(title: queue.jobs.first { $0.id == job.id }?.state.label ?? "", action: nil, keyEquivalent: "")
            state.isEnabled = false
            let cancel = NSMenuItem(title: "Cancel", action: #selector(MenuProgressCancelTarget.cancel(_:)), keyEquivalent: "")
            cancel.target = target
            [title, state, cancel].forEach(menu.addItem)
        }
        return menu
    }

    func testTrackingUsesReplacementQueueAtNextTickAndNextMenu() async throws {
        let oldDir = try makeTempDirectory(prefix: "menu_progress_old_queue_test")
        let newDir = try makeTempDirectory(prefix: "menu_progress_new_queue_test")
        let oldQueue = PipelineQueue(logDir: oldDir)
        let newQueue = PipelineQueue(logDir: newDir)
        let job = PipelineJob(
            meetingTitle: "Sprint", appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        oldQueue.enqueue(job)
        oldQueue.updateJobState(id: job.id, to: .diarizing)
        newQueue.enqueue(job)
        newQueue.updateJobState(id: job.id, to: .diarizing)
        let source = MenuProgressQueueSource(oldQueue)
        let updater = MenuStageProgressUpdater()
        updater.observe { source.queue }

        let firstMenu = NSMenu()
        let firstTitle = NSMenuItem(title: job.meetingTitle, action: nil, keyEquivalent: "")
        firstTitle.isEnabled = false
        firstMenu.addItem(firstTitle)
        let firstProgress = NSMenuItem(title: JobState.diarizing.label, action: nil, keyEquivalent: "")
        firstProgress.isEnabled = false
        firstMenu.addItem(firstProgress)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: firstMenu)
        await waitForTitleChange(firstProgress, from: JobState.diarizing.label)
        XCTAssertTrue(firstProgress.title.hasPrefix("Diarizing... "), firstProgress.title)

        // The old queue's job is parked at naming, so only the replacement queue
        // can still change this row. Nothing runs between the capture and the
        // swap, so no tick of the old queue can slip in.
        let beforeSwap = firstProgress.title
        oldQueue.updateJobState(id: job.id, to: .speakerNamingPending)
        source.queue = newQueue
        await waitForTitleChange(firstProgress, from: beforeSwap)
        XCTAssertNotEqual(firstProgress.title, beforeSwap)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: firstMenu)
        try await Task.sleep(for: .milliseconds(20))

        let secondMenu = NSMenu()
        let secondTitle = NSMenuItem(title: job.meetingTitle, action: nil, keyEquivalent: "")
        secondTitle.isEnabled = false
        secondMenu.addItem(secondTitle)
        let secondProgress = NSMenuItem(title: JobState.diarizing.label, action: nil, keyEquivalent: "")
        secondProgress.isEnabled = false
        secondMenu.addItem(secondProgress)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: secondMenu)
        defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: secondMenu) }
        await waitForTitleChange(secondProgress, from: JobState.diarizing.label)
        XCTAssertTrue(secondProgress.title.hasPrefix("Diarizing... "), secondProgress.title)
    }

    private func waitForTitleChange(_ item: NSMenuItem, from initial: String) async {
        await waitFor({ item.title != initial }, timeout: .seconds(3))
    }
}

/// Carries a menu item into a main-queue block; it is only touched on the main thread.
private struct MenuItemBox: @unchecked Sendable {
    let item: NSMenuItem
}

/// Written from the `@Sendable` observation callback, read by the test.
private final class InvalidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.withLock { raised }
    }

    func raise() {
        lock.withLock { raised = true }
    }
}

@MainActor
private final class MenuProgressQueueSource {
    var queue: PipelineQueue

    init(_ queue: PipelineQueue) {
        self.queue = queue
    }
}

@MainActor
private final class MenuProgressCancelTarget: NSObject {
    let queue: PipelineQueue
    let jobID: UUID
    var callCount = 0

    init(queue: PipelineQueue, jobID: UUID) {
        self.queue = queue
        self.jobID = jobID
    }

    @objc
    func cancel(_: NSMenuItem) {
        callCount += 1
        queue.cancelJob(id: jobID)
    }
}
