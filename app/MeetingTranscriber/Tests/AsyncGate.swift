import Foundation

/// One-shot async gate: lets a test park an injected `async` seam and release it
/// on cue, so a race is ordered rather than timing-dependent.
///
/// `hasWaiter` is what makes it usable for ordering rather than only for
/// releasing: opening the gate controls when the parked side resumes, but a test
/// usually also needs to know the parked side has *arrived* before racing
/// something against it.
///
/// Its own file rather than `TestHelpers.swift`, which is at its 600-line limit.
/// Near-identical continuation gates are already inlined in several suites; this
/// is the standalone version, so new callers have somewhere to reach for.
actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    var hasWaiter: Bool {
        !continuations.isEmpty
    }

    var waiterCount: Int {
        continuations.count
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// The main-actor sibling of `AsyncGate`, for seams that are already isolated to
/// the main actor.
///
/// `open()` is synchronous so that a releasing caller keeps the actor from the
/// release to its own first real suspension. That is what makes a test's ordering
/// hold by construction: the joined-load tests in
/// `WhisperKitEngineModelSourceTests` release a parked load and must then reach
/// the join inside `SingleFlight` before the released side can finish its flight,
/// and `await gate.open()` on the actor version suspends right between the two.
///
/// Not a failure that was observed: with the actor version those two tests still
/// passed ten runs out of ten. The difference is that their ordering then rests on
/// how the two continuations happen to be scheduled rather than on the code, and
/// the assertion that would catch it is an indirect one (a joiner that ran its own
/// flight shows up as a third entry in `pipeVariants`).
///
/// It is also one-shot in a way callers rely on: once open, a later `wait()`
/// returns immediately, so a seam that is entered twice parks only on its first
/// pass without the caller tracking that itself.
@MainActor
final class MainActorGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume()
        }
    }
}
