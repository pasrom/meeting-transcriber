import Foundation

/// Runs bodies that share a key one at a time, first come first served: a caller
/// whose key is held waits until the body holding it returns, then runs its own.
/// Bodies under different keys do not wait for each other. A body is never
/// interrupted, and the wait ignores cancellation.
///
/// Unlike `SingleFlight`, a caller that waited runs its own body instead of taking
/// the running one's outcome. Unlike `AsyncSerialGate`, it is main-actor isolated,
/// so a body can touch main-actor state, and one instance serves several keys.
@MainActor
final class KeyedSerialGate {
    /// Per held key, the callers waiting for it, in arrival order.
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func run<T>(_ key: String, _ body: () async throws -> T) async rethrows -> T {
        if waiters[key] == nil {
            waiters[key] = []
        } else {
            // Resumed by the holder, which hands the key over without freeing it,
            // so no caller arriving in between can slip past.
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }
        defer {
            if let next = waiters[key]?.first {
                waiters[key]?.removeFirst()
                next.resume()
            } else {
                waiters[key] = nil
            }
        }
        return try await body()
    }
}
