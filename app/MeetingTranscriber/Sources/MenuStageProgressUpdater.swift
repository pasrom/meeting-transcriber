import AppKit
import Combine

/// Update progress on the existing native menu item. Rebuilding SwiftUI menu
/// content on elapsed-time ticks or stage changes displaces Cancel's highlight.
@MainActor
final class MenuStageProgressUpdater {
    private var timer: Timer?
    private weak var trackedMenu: NSMenu?
    private var queueProvider: (@MainActor () -> PipelineQueue?)?
    private var subscriptions: Set<AnyCancellable> = []
    private var trackingMenus: [ObjectIdentifier: PipelineQueue] = [:]

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

    private func beginTracking(menu: NSMenu, queue: PipelineQueue) {
        if trackingMenus[ObjectIdentifier(menu)] == nil {
            trackingMenus[ObjectIdentifier(menu)] = queue
            queue.beginMenuTracking()
        }
        timer?.invalidate()
        trackedMenu = menu
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
                      let queue = self.queueProvider?() else { return }
                self.refresh(menu: menu, queue: queue)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endTracking(menu: NSMenu) {
        trackingMenus.removeValue(forKey: ObjectIdentifier(menu))?.endMenuTracking()
        guard trackedMenu === menu else { return }
        timer?.invalidate()
        timer = nil
        trackedMenu = nil
    }

    /// Every heading `MenuBarView` can put above the job list. All of them, not
    /// the one for the current states: the menu may still show the previous one
    /// when a tick lands between two renders.
    private static let queueHeaderTitles = Set(QueueHeader.all.map(\.title))

    /// SwiftUI does not forward Text accessibility identifiers to NSMenuItem, so
    /// a job's rows are found by position. The menu lists the jobs in queue
    /// order, each as a disabled title row, a disabled state row, then its
    /// actions. Walking both in step with a cursor resolves equal titles by
    /// order (auto-titles such as "Zoom Meeting" repeat), and an enabled action
    /// row can never be taken for a title, whatever a meeting is called.
    ///
    /// The walk starts below the queue heading, the first row carrying one of the
    /// heading titles: it precedes every job, so a job called "Queue" or
    /// "Processing" cannot be taken for it. Above it sit the running
    /// meeting's title, an error line and the status detail, and a recording
    /// that shares a job's auto-title would otherwise take that job's place.
    /// Without a heading in the menu the walk starts at the top, as before.
    func refresh(menu: NSMenu, queue: PipelineQueue) {
        let items: [NSMenuItem] = menu.items
        var cursor = items.firstIndex { item in
            !item.isEnabled && !item.isSeparatorItem && Self.queueHeaderTitles.contains(item.title)
        }.map { $0 + 1 } ?? 0
        for job in queue.jobs {
            guard let titleIndex = items[cursor...].firstIndex(where: { item in
                !item.isEnabled && !item.isSeparatorItem && item.title == job.meetingTitle
            }) else { continue }
            let stateIndex = titleIndex + 1
            cursor = min(stateIndex + 1, items.count)
            guard StageKind(jobState: job.state) != nil, items.indices.contains(stateIndex) else { continue }
            let stateRow = items[stateIndex]
            // The displayed prefix can still name the stage we just left.
            guard !stateRow.isEnabled, Self.hasStagePrefix(stateRow.title) else { continue }
            let text = Self.progressText(job: job, queue: queue)
            if stateRow.title != text { stateRow.title = text }
        }
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
