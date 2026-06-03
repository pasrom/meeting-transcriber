import Foundation

/// Single-flight coordinator: runs an idempotent async operation at most once
/// concurrently. The first caller kicks off the work; callers that arrive while
/// it is in flight await the same run instead of starting their own. Once the
/// run finishes the coordinator re-arms, so a later call starts fresh.
///
/// This is the shared scaffolding behind the three ASR engines' `loadModel()`
/// dedup (WhisperKit / Parakeet / Qwen3), which otherwise repeated the same
/// `loadingTask` machinery verbatim. The body owns its own error handling and
/// state transitions; this type only owns the dedup.
///
/// The in-flight `Task` is cleared once the body returns — on every path, since
/// the body is non-throwing and handles its own failures — so a failed load
/// doesn't latch a poisoned task that replays the failure to every future
/// caller (see [[feedback-single-flight-clear-loadingtask-on-failure]]).
@MainActor
final class SingleFlight {
    private var task: Task<Void, Never>?

    /// Run `body`, deduplicating against any run already in flight. Returns once
    /// the run this call observed (its own, or the one it joined) has finished.
    func run(_ body: @escaping @MainActor () async -> Void) async {
        if let existing = task {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await body()
            self.task = nil
        }
        self.task = task
        await task.value
    }
}
