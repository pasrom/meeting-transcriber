import Foundation

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
@MainActor
final class SingleFlight<Outcome: Sendable> {
    private var task: Task<Outcome, Never>?

    /// Run `body`, deduplicating against any run already in flight. Returns once
    /// the run this call observed (its own, or the one it joined) has finished,
    /// yielding that run's outcome.
    func run(_ body: @escaping @MainActor () async -> Outcome) async -> Outcome {
        if let existing = task {
            return await existing.value
        }
        let task = Task { @MainActor in
            let outcome = await body()
            self.task = nil
            return outcome
        }
        self.task = task
        return await task.value
    }
}
