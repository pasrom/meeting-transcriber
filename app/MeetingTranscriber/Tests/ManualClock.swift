import Foundation
import os

/// A clock that moves only when a test advances it, for a limit that has to
/// pass at a point the test chooses rather than after a real wait. A sleep
/// ends when `advance(by:)` reaches its deadline, or with a
/// `CancellationError` when its task is cancelled.
///
/// For code that takes `any Clock<Duration>`, such as `BoundedProcess`;
/// `TestClock` serves `WatchLoop`'s closure-injected timing.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var elapsed: Duration

        func advanced(by duration: Duration) -> Self {
            Self(elapsed: elapsed + duration)
        }

        func duration(to other: Self) -> Duration {
            other.elapsed - elapsed
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.elapsed < rhs.elapsed
        }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(elapsed: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .zero
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id = state.withLock { current in
            defer { current.nextID += 1 }
            return current.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The cancel flag is set before the handler below runs, so a
                // sleep registered under the lock after a cancel sees it here,
                // and one registered before is found by the handler.
                let outcome: Result<Void, any Error>? = state.withLock { current in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= current.now { return .success(()) }
                    current.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper = state.withLock { current in
                current.sleepers.firstIndex { $0.id == id }.map { current.sleepers.remove(at: $0) }
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and ends every sleep whose deadline it
    /// reaches. Waits first, for up to five seconds, for something to be
    /// sleeping on the clock: the limit a test means to let pass is set
    /// only once its process has been started, so it can still be on its
    /// way when the test has seen the process run.
    func advance(by duration: Duration) async {
        let sleptBy = ContinuousClock.now + .seconds(5)
        while state.withLock({ $0.sleepers.isEmpty }), ContinuousClock.now < sleptBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let due = state.withLock { current in
            current.now = current.now.advanced(by: duration)
            let pending = current.sleepers.partition { $0.deadline <= current.now }
            defer { current.sleepers.removeSubrange(pending...) }
            return Array(current.sleepers[pending...])
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}
