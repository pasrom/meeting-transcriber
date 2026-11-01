import Foundation
import os

/// Single-flight coordinator: runs an idempotent async operation at most once
/// concurrently. The first caller kicks off the work; callers that arrive while
/// it is in flight await the same run instead of starting their own. Once the
/// run finishes the coordinator re-arms, so a later call starts fresh.
///
/// This is the shared scaffolding behind the two ASR engines' `loadModel()`
/// dedup (WhisperKit / Parakeet), which otherwise repeated the same
/// `loadingTask` machinery verbatim. The body owns its own error handling and
/// state transitions; this type only owns the dedup.
///
/// The in-flight `Task` is cleared once the body returns, on every path, since
/// the body is non-throwing and handles its own failures, so a failed load
/// doesn't latch a poisoned task that replays the failure to every future
/// caller.
///
/// `run` hands back the outcome of the run the caller observed, its own or the one
/// it joined, so a joiner can learn what the flight it waited on attempted. Callers
/// that do not need it use `Outcome == Void`.
///
/// The run itself is never cancelled: it is shared, and whoever is still
/// waiting, or comes next, wants its result. A caller that should not wait for
/// it once cancelled uses `runUnlessCancelled`.
@MainActor
final class SingleFlight<Outcome: Sendable> {
    private var flight: (task: Task<Outcome, Never>, joiners: Joiners<Outcome>)?

    /// Run `body`, deduplicating against any run already in flight. Returns once
    /// the run this call observed (its own, or the one it joined) has finished,
    /// yielding that run's outcome. Ignores the caller's cancellation.
    func run(_ body: @escaping @MainActor () async -> Outcome) async -> Outcome {
        await start(body).task.value
    }

    /// Like `run`, but throws `CancellationError` as soon as the caller is
    /// cancelled instead of waiting for the run to finish. The run is started
    /// or joined even by a caller already cancelled, so it is under way for
    /// whoever comes next; only the wait ends early.
    func runUnlessCancelled(_ body: @escaping @MainActor () async -> Outcome) async throws -> Outcome {
        let joiners = start(body).joiners
        let id = joiners.makeID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { joiners.wait(id, $0) }
        } onCancel: {
            joiners.cancel(id)
        }
    }

    private func start(
        _ body: @escaping @MainActor () async -> Outcome,
    ) -> (task: Task<Outcome, Never>, joiners: Joiners<Outcome>) {
        if let flight { return flight }
        let joiners = Joiners<Outcome>()
        let task = Task { @MainActor in
            let outcome = await body()
            self.flight = nil
            joiners.finish(with: outcome)
            return outcome
        }
        let flight = (task: task, joiners: joiners)
        self.flight = flight
        return flight
    }
}

/// The callers of one run that wait through `runUnlessCancelled`: each is
/// resumed once, by the run's outcome or by its own cancellation, whichever
/// comes first. Cancellation handlers run on any thread, hence the lock.
private final class Joiners<Outcome: Sendable>: Sendable {
    private struct State {
        var nextID = 0
        var waiting: [Int: CheckedContinuation<Outcome, any Error>] = [:]
        /// Cancelled before their continuation was handed in.
        var cancelled: Set<Int> = []
        var outcome: Outcome?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func makeID() -> Int {
        state.withLock { current in
            defer { current.nextID += 1 }
            return current.nextID
        }
    }

    func wait(_ id: Int, _ continuation: CheckedContinuation<Outcome, any Error>) {
        let resolved: Result<Outcome, any Error>? = state.withLock { current in
            if current.cancelled.remove(id) != nil { return .failure(CancellationError()) }
            if let outcome = current.outcome { return .success(outcome) }
            current.waiting[id] = continuation
            return nil
        }
        if let resolved { continuation.resume(with: resolved) }
    }

    func cancel(_ id: Int) {
        let continuation = state.withLock { current in
            guard let continuation = current.waiting.removeValue(forKey: id) else {
                if current.outcome == nil { current.cancelled.insert(id) }
                return nil as CheckedContinuation<Outcome, any Error>?
            }
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func finish(with outcome: Outcome) {
        let waiting = state.withLock { current in
            current.outcome = outcome
            defer { current.waiting = [:] }
            return Array(current.waiting.values)
        }
        for continuation in waiting {
            continuation.resume(returning: outcome)
        }
    }
}
