import Foundation
import os

/// Counts work handed to tasks of its own, so a caller can wait, bounded, until
/// none is left. `enter()` runs where the work is handed off, before its task
/// exists, so the count never misses a task that has not started yet.
final class InFlightCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func enter() {
        count.withLock { $0 += 1 }
    }

    func leave() {
        count.withLock { $0 -= 1 }
    }

    private var isIdle: Bool {
        count.withLock { $0 <= 0 }
    }

    /// True once nothing is in flight, false when `timeout` passed first. Polls,
    /// because awaiting a task's value cannot be abandoned at a deadline.
    func waitUntilIdle(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isIdle {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
