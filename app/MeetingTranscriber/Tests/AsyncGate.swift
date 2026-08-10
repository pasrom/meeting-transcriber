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
