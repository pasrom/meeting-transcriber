import Foundation

/// Mutual exclusion for async work, first come first served. A caller that
/// finds the gate held suspends instead of blocking a thread, and is resumed
/// when the holder leaves.
///
/// An actor alone would not do this: actor methods are reentrant at every
/// `await`, so two callers of an async method would interleave inside it.
/// Here the actor only guards the held flag and the waiting list; the work
/// itself runs outside it, in `withGate`.
actor AsyncSerialGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        // `release` hands the gate over without clearing `isHeld`, so no
        // caller arriving in between can slip past the waiters.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` once every earlier caller has left the gate. The gate is
    /// released whether `body` returns or throws.
    nonisolated func withGate<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}
