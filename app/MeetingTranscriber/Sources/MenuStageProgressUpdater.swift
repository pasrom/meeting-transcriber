import AppKit
import Combine

/// Update progress on the existing native menu item. Rebuilding SwiftUI menu
/// content on elapsed-time ticks or stage changes displaces Cancel's highlight.
@MainActor
final class MenuStageProgressUpdater {
    private var timer: Timer?
    private weak var trackedMenu: NSMenu?
    private weak var queue: PipelineQueue?
    private var queueProvider: (@MainActor () -> PipelineQueue?)?
    private var subscriptions: Set<AnyCancellable> = []

    func observe(queueProvider: @escaping @MainActor () -> PipelineQueue?) {
        self.queueProvider = queueProvider
        subscriptions.removeAll()
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { @Sendable [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let event = MenuTrackingEvent(menu)
                Task { @MainActor in
                    guard let self, let queue = self.queueProvider?() else { return }
                    self.beginTracking(menu: event.menu, queue: queue)
                }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { @Sendable [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let event = MenuTrackingEvent(menu)
                Task { @MainActor in
                    self?.endTracking(menu: event.menu)
                }
            }
            .store(in: &subscriptions)
    }

    func beginTracking(menu: NSMenu, queue: PipelineQueue) {
        timer?.invalidate()
        trackedMenu = menu
        self.queue = queue
        refresh(menu: menu, queue: queue)
        let timer = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // Native menu tracking runs a nested run loop. Enter MainActor
            // explicitly rather than inheriting it in the timer callback.
            Task { @MainActor in
                guard let menu = self.trackedMenu,
                      let queue = self.queueProvider?() ?? self.queue else { return }
                self.refresh(menu: menu, queue: queue)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func endTracking(menu: NSMenu) {
        guard trackedMenu === menu else { return }
        timer?.invalidate()
        timer = nil
        trackedMenu = nil
        queue = nil
    }

    func refresh(menu: NSMenu, queue: PipelineQueue) {
        let items: [NSMenuItem] = menu.items
        let jobs: [PipelineJob] = queue.jobs
        for index in items.indices where index > 0 {
            refresh(item: items[index], after: items[index - 1].title, jobs: jobs, queue: queue)
        }
    }

    private func refresh(item: NSMenuItem, after title: String, jobs: [PipelineJob], queue: PipelineQueue) {
        guard !item.isEnabled else { return }
        // SwiftUI does not forward Text accessibility identifiers to
        // NSMenuItem. Match the job's adjacent title and active-stage row.
        // The displayed prefix can still name the stage we just left.
        guard Self.hasStagePrefix(item.title) else { return }
        guard let job = Self.activeJob(titled: title, in: jobs) else { return }
        let text = Self.progressText(job: job, queue: queue)
        if item.title != text { item.title = text }
    }

    private static func activeJob(titled title: String, in jobs: [PipelineJob]) -> PipelineJob? {
        for job in jobs {
            guard StageKind(jobState: job.state) != nil else { continue }
            if job.meetingTitle == title { return job }
        }
        return nil
    }

    private static func hasStagePrefix(_ title: String) -> Bool {
        [JobState.transcribing, .diarizing, .generatingProtocol].contains { title.hasPrefix($0.label) }
    }

    static func progressText(job: PipelineJob, queue: PipelineQueue) -> String {
        let elapsed = queue.elapsedSeconds(forJobID: job.id)
        let base = "\(job.state.label) \(formattedTime(elapsed))"
        guard let stage = StageKind(jobState: job.state),
              let avg = queue.averageSeconds(forJobID: job.id, stage: stage), avg > 0 else { return base }
        let suffix = StageTimingStats.isSlowerThanUsual(elapsed: elapsed, average: avg)
            ? " · longer than usual (Ø \(formattedTime(avg)))"
            : " · Ø \(formattedTime(avg))"
        return base + suffix
    }
}

/// The older AppKit SDK does not make NSMenu Sendable. Carry its reference
/// across the notification callback, but expose it only on MainActor.
private struct MenuTrackingEvent: @unchecked Sendable {
    private let reference: NSMenu

    init(_ menu: NSMenu) {
        reference = menu
    }

    @MainActor var menu: NSMenu {
        reference
    }
}
