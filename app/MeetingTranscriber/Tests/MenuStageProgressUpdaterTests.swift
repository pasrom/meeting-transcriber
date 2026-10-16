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

    func testElapsedTicksDoNotInvalidateMenuObservation() async throws {
        let dir = try makeTempDirectory(prefix: "menu_progress_observation_test")
        let queue = PipelineQueue(logDir: dir)
        let job = PipelineJob(
            meetingTitle: "Sprint", appName: "Zoom",
            mixPath: dir.appendingPathComponent("mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .diarizing)
        withObservationTracking {
            _ = queue.elapsedSeconds(forJobID: job.id)
        } onChange: {
            XCTFail("Elapsed ticks must not rebuild the SwiftUI menu")
        }

        let before = queue.elapsedSeconds(forJobID: job.id)
        try await Task.sleep(for: .milliseconds(1200))

        XCTAssertGreaterThan(queue.elapsedSeconds(forJobID: job.id), before + 1)
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
        firstMenu.addItem(NSMenuItem(title: job.meetingTitle, action: nil, keyEquivalent: ""))
        let firstProgress = NSMenuItem(title: JobState.diarizing.label, action: nil, keyEquivalent: "")
        firstProgress.isEnabled = false
        firstMenu.addItem(firstProgress)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: firstMenu)
        await waitForTitleChange(firstProgress, from: JobState.diarizing.label)
        XCTAssertEqual(firstProgress.title, "Diarizing... 0s")

        oldQueue.updateJobState(id: job.id, to: .speakerNamingPending)
        source.queue = newQueue
        await waitForTitleChange(firstProgress, from: "Diarizing... 0s")
        XCTAssertNotEqual(firstProgress.title, "Diarizing... 0s")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: firstMenu)
        try await Task.sleep(for: .milliseconds(20))

        let secondMenu = NSMenu()
        secondMenu.addItem(NSMenuItem(title: job.meetingTitle, action: nil, keyEquivalent: ""))
        let secondProgress = NSMenuItem(title: JobState.diarizing.label, action: nil, keyEquivalent: "")
        secondProgress.isEnabled = false
        secondMenu.addItem(secondProgress)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: secondMenu)
        defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: secondMenu) }
        await waitForTitleChange(secondProgress, from: JobState.diarizing.label)
        XCTAssertNotEqual(secondProgress.title, "Diarizing... 0s")
    }

    private func waitForTitleChange(_ item: NSMenuItem, from initial: String) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while item.title == initial, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
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
