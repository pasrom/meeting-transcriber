import Foundation

/// Coordinates an async yes/no prompt (issue #503): register a pending decision
/// for an id, then resolve it exactly once — by an external answer or a timeout,
/// whichever comes first (race-safe, remove-on-resolve). Pure: no
/// UI / UNUserNotificationCenter dependency, and the timeout clock is injected,
/// so the park / resolve / timeout / race logic is deterministically unit-testable.
/// `NotificationManager` wires the raw `UNUserNotificationCenter` add + delegate
/// to this (that thin glue stays the only untested part — Apple's framework isn't
/// ours to test).
///
/// `@unchecked Sendable`: `pending`/`timeouts` are guarded by `lock`, since the
/// notification delegate and the timeout task resolve from arbitrary queues.
final class ConsentPromptCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<Bool, Never>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]

    private let timeout: TimeInterval
    /// Sleep primitive for the timeout. Defaults to `Task.sleep`; tests inject a
    /// controllable one (instant to force a timeout, or long to let a resolve win).
    private let sleep: @Sendable (TimeInterval) async -> Void

    init(
        timeout: TimeInterval = 60,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
    ) {
        self.timeout = timeout
        self.sleep = sleep
    }

    /// Await the decision for `id`. `onParked` runs once the continuation is
    /// registered (the caller posts the notification there, so a fast answer
    /// can't race ahead of registration). Resolves via `resolve(id:granted:)`
    /// or, if unanswered, `false` after the timeout.
    func awaitDecision(id: String, onParked: @Sendable () -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let sleep = self.sleep
            let timeout = self.timeout
            let timeoutTask = Task { [weak self] in
                await sleep(timeout)
                guard !Task.isCancelled else { return }
                self?.resolve(id: id, granted: false)
            }

            lock.lock()
            pending[id] = continuation
            timeouts[id] = timeoutTask
            lock.unlock()

            onParked()
        }
    }

    /// Resolve `id` exactly once — the first caller (answer or timeout) wins and
    /// removes it; later calls no-op. Cancels the timeout task so it doesn't
    /// linger once an answer arrives.
    func resolve(id: String, granted: Bool) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        let timeoutTask = timeouts.removeValue(forKey: id)
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(returning: granted)
    }

    /// Resolve every currently-pending prompt at once with `granted`, returning
    /// whether at least one was waiting. The debug-RPC consent hook (issue #503)
    /// has no prompt id — "resolve whatever is parked" is the only sensible
    /// semantics for a test hook, and a `false` no-op when nothing waits lets the
    /// driver poll until a prompt actually parks. The drain happens under the
    /// lock so two racing callers can't double-resume the same continuation.
    @discardableResult
    func resolvePending(granted: Bool) -> Bool {
        lock.lock()
        let continuations = Array(pending.values)
        let timeoutTasks = Array(timeouts.values)
        pending.removeAll()
        timeouts.removeAll()
        lock.unlock()
        for task in timeoutTasks {
            task.cancel()
        }
        for continuation in continuations {
            continuation.resume(returning: granted)
        }
        return !continuations.isEmpty
    }
}
