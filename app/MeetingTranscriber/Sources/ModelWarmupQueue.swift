import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ModelWarmupQueue")

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
/// chains each op after the previous op has finished, which does serialize.
/// `run` awaits its op, so callers keep their existing "await until loaded"
/// contract; the queue only orders the loads, it does not replace each
/// engine's own concurrent-load dedupe or its failure handling.
///
/// Each op is logged when it starts and when it finishes, with its label and
/// durations, and with a warning when it is still running `stallDeadline` after
/// it started. A load that never returns otherwise leaves nothing in the log
/// that says which one it is. The warning does not stop the op.
@MainActor
final class ModelWarmupQueue {
    /// Waits for the stall deadline; injectable so tests decide when it passes.
    typealias Sleep = @MainActor (Duration) async throws -> Void

    /// Five times the longest warm-up measured (59.9 s, a first Nemotron
    /// warm-up); a slow first model download can still reach it.
    static let defaultStallDeadline: Duration = .seconds(300)

    /// How long an op may run before the queue reports it as stalled.
    let stallDeadline: Duration
    private let sleep: Sleep

    /// The most recently enqueued op. Each new op waits until this one has
    /// finished, then becomes the new tail.
    private var tail: Slot?

    init(
        stallDeadline: Duration = ModelWarmupQueue.defaultStallDeadline,
        // The suspending clock, so a Mac asleep with a load in flight does not
        // wake to a stall: only time awake counts.
        sleep: @escaping Sleep = { try await Task.sleep(for: $0, tolerance: nil, clock: .suspending) },
    ) {
        self.stallDeadline = stallDeadline
        self.sleep = sleep
    }

    /// Enqueue `op` to run after every previously-enqueued op has finished, and
    /// await its completion. At most one op runs at a time. `label` names the op
    /// in the log; `onStall` runs once if the op is still running
    /// `stallDeadline` after it started.
    func run(
        _ label: String,
        onStall: (@MainActor () -> Void)? = nil,
        _ op: @escaping @MainActor () async -> Void,
    ) async {
        let predecessor = tail
        let slot = Slot(label: label)
        tail = slot
        if let predecessor, !predecessor.isFinished {
            logger.notice("Warm-up queue: \(label, privacy: .public) waits for \(predecessor.label, privacy: .public)")
        }
        let enqueued = Date()
        let deadline = stallDeadline
        let sleep = sleep
        // An unstructured Task, so a cancelled caller does not cancel the load.
        let task = Task { @MainActor in
            await predecessor?.waitUntilFinished()
            let started = Date()
            logger.notice(
                "Warm-up queue: \(label, privacy: .public) started after waiting \(started.timeIntervalSince(enqueued), format: .fixed(precision: 1), privacy: .public) s",
            )
            let watchdog = Task { @MainActor in
                do { try await sleep(deadline) } catch { return }
                guard !slot.isFinished else { return }
                logger.warning(
                    "Warm-up queue: \(label, privacy: .public) still running after \(deadline.components.seconds, privacy: .public) s",
                )
                onStall?()
            }
            await op()
            watchdog.cancel()
            slot.finish()
            logger.notice(
                "Warm-up queue: \(label, privacy: .public) finished after \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) s",
            )
        }
        await task.value
    }
}

/// One enqueued op's place in the chain.
@MainActor
private final class Slot {
    let label: String
    private(set) var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(label: String) {
        self.label = label
    }

    func waitUntilFinished() async {
        if isFinished { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}
