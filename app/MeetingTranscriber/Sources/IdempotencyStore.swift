#if !APPSTORE
    import Foundation

    /// Bounded FIFO map of `Idempotency-Key` -> created job IDs, so a repeated
    /// automation request carrying the same key returns the original job(s)
    /// instead of enqueuing duplicates.
    ///
    /// In-memory, per `DebugRPCServer` instance: the dedup window is a session,
    /// which is all client retry-dedup needs (a toggle off/on resets it). The
    /// FIFO cap stops an unbounded leak on a long-running headless server.
    ///
    /// The key is recorded after the job is created, so this dedupes *sequential*
    /// retries (a client re-sending after a response or timeout, the common
    /// case). Two same-key requests racing in-flight can both enqueue; hardening
    /// that needs reserve-before-work and is left as a follow-up.
    struct IdempotencyStore {
        private var byKey: [String: [UUID]] = [:]
        private var order: [String] = []
        let capacity: Int

        init(capacity: Int = 1024) {
            self.capacity = capacity
        }

        // Optional, not empty-collection: nil (key never seen) must be
        // distinguishable from [] (key seen, but the enqueue matched no files),
        // else a fresh key would be mistaken for a duplicate and skip enqueuing.
        // swiftlint:disable:next discouraged_optional_collection
        func lookup(_ key: String) -> [UUID]? {
            byKey[key]
        }

        mutating func remember(_ key: String, _ ids: [UUID]) {
            if byKey[key] == nil {
                order.append(key)
                if order.count > capacity {
                    byKey.removeValue(forKey: order.removeFirst())
                }
            }
            byKey[key] = ids
        }
    }
#endif
