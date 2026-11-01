import Foundation
import os
import XCTest

/// How long a test waits for something a correct run does at once or at a
/// deadline the test controls. Only a regression ever reaches it, so it is
/// generous: the verdict is the event, never the time it took.
let regressionCeiling: Duration = .seconds(10)

/// How `body` ended, as text an assertion compares: "returned",
/// "cancelled" for a `CancellationError`, or the error it failed with.
@MainActor
func outcome(of body: () async throws -> Void) async -> String {
    do {
        try await body()
        return "returned"
    } catch is CancellationError {
        return "cancelled"
    } catch {
        return "failed with \(error)"
    }
}

@MainActor
extension XCTestCase {
    /// What `task` returned, or nil when it has not returned within
    /// `ceiling`. For a call that must answer while the test still holds
    /// what it would otherwise wait for: a regression then fails here
    /// instead of hanging the run. On expiry `task` is cancelled; a call that
    /// ignores cancellation runs on (and the observer with it, since
    /// `Task.value` ignores cancellation too) until the test releases what it
    /// waits for, so it must record only into state the failed test owns,
    /// never into anything a later test reads.
    func value<T: Sendable>(of task: Task<T, Never>, within ceiling: Duration = regressionCeiling) async -> T? {
        let settled = OSAllocatedUnfairLock<T?>(initialState: nil)
        Task {
            let value = await task.value
            settled.withLock { $0 = value }
        }
        await waitFor({ settled.withLock { $0 != nil } }, timeout: ceiling)
        guard let value = settled.withLock({ $0 }) else {
            task.cancel()
            return nil
        }
        return value
    }
}
