import Foundation

/// Tasks a quit has to wait for, each removing itself when it ends: a watch
/// task, which goes on after `WatchLoop.stop()` cancels it to finish the
/// recording it was in, and the stop of a manual recording. Both mix off the
/// main actor, so a loop can be stopped, or let go of, in the middle of a mix.
///
/// `WatchingController` hands one to every loop it builds, so a loop it has
/// already let go of (Stop Watching in the middle of a meeting) is still
/// waited for by a quit.
@MainActor
final class UnfinishedWork {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var isEmpty: Bool {
        tasks.isEmpty
    }

    /// Run `work` in a task of its own, held here until it ends.
    func track(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await work()
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }

    /// Return once every task held here has ended, including any a task
    /// still running starts on its way.
    func waitForAll() async {
        while let task = tasks.values.first {
            await task.value
        }
    }
}
