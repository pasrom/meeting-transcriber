import Foundation

/// Serial gate that runs model warm-up loads one at a time, FIFO.
///
/// At launch the ASR engine model and the live-caption streaming models load on
/// independent Tasks. Compiling/loading them concurrently produces a
/// simultaneous ANE + CoreML-compiler + CPU peak that, when it coincides with a
/// meeting join, starves WindowServer and makes the whole machine sluggish for
/// the first seconds of the call. Routing every warm-up load through one shared
/// queue keeps at most one compiling at a time, so the total work is spread out
/// instead of hitting all at once.
///
/// A plain actor would NOT serialize: actor methods are reentrant at every
/// `await`, so two overlapping `run` calls would interleave their ops. This
/// chains each op after the previous op's `Task` has completed, which does
/// serialize. `run` awaits its op, so callers keep their existing "await until
/// loaded" contract; the queue only orders the loads, it does not replace each
/// engine's own concurrent-load dedupe or its failure handling.
@MainActor
final class ModelWarmupQueue {
    /// The most recently enqueued op's task. Each new op waits on this before
    /// running, then becomes the new tail. `Task<Void, Never>` never throws, so
    /// an op that fails internally cannot poison the chain for later ops.
    private var tail: Task<Void, Never>?

    /// Enqueue `op` to run after every previously-enqueued op has finished, and
    /// await its completion. At most one op runs at a time.
    func run(_ op: @escaping @MainActor () async -> Void) async {
        let predecessor = tail
        let task = Task { @MainActor in
            await predecessor?.value
            await op()
        }
        tail = task
        await task.value
    }
}
