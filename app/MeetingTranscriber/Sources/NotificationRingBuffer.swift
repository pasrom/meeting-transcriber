#if !APPSTORE
    import Foundation
    import os

    /// Bounded, thread-safe log of the most recent notifications the app posted.
    ///
    /// Recorded at the single `NotificationManager.notify(...)` chokepoint so every
    /// caller (pipeline callbacks, `WatchLoop`, channel-health, permission-health,
    /// sidecar-write failures, ...) is captured without touching call sites, and
    /// read by the dev-only debug RPC `/state.notifications` snapshot. That surface
    /// makes user-facing warning paths observable to E2E assertions, which today
    /// cannot see a posted `UNUserNotification` from outside the process.
    ///
    /// The whole type is `#if !APPSTORE`: its only reader is the debug RPC, so the
    /// sandboxed App Store variant doesn't retain notification strings it can
    /// never serve.
    ///
    /// `@unchecked Sendable`: `notify(...)` is invoked from arbitrary actors and
    /// framework queues, so the entry array is guarded by an `OSAllocatedUnfairLock`
    /// (same pattern as `LevelPublisher`).
    final class NotificationRingBuffer: @unchecked Sendable {
        struct Entry: Equatable {
            let title: String
            let body: String
            let postedAt: Date
            /// Whether the notification passed the delivery guard and was handed
            /// to `UNUserNotificationCenter`. `false` means the app *decided* to
            /// notify but nothing reached the user (no bundle / `setUp()` never
            /// ran) — E2E assertions about user-visible warnings must check this.
            let delivered: Bool
        }

        /// Most entries retained; oldest evicted first once exceeded.
        static let defaultCapacity = 50

        private let capacity: Int
        private let now: @Sendable () -> Date
        private let state = OSAllocatedUnfairLock<[Entry]>(initialState: [])

        /// `capacity` and `now` are injectable so the eviction/timestamp behaviour is
        /// unit-testable without posting the full 50 entries or leaning on wall-clock.
        init(capacity: Int = NotificationRingBuffer.defaultCapacity, now: @escaping @Sendable () -> Date = { Date() }) {
            precondition(capacity > 0, "NotificationRingBuffer capacity must be positive")
            self.capacity = capacity
            self.now = now
        }

        /// Append a posted notification, dropping the oldest if over capacity.
        func record(title: String, body: String, delivered: Bool) {
            state.withLock { entries in
                entries.append(Entry(title: title, body: body, postedAt: now(), delivered: delivered))
                if entries.count > capacity {
                    entries.removeFirst(entries.count - capacity)
                }
            }
        }

        /// Snapshot of retained entries in chronological order (newest last), the
        /// same ordering the RPC `notifications` array contracts.
        var entries: [Entry] {
            state.withLock { $0 }
        }
    }
#endif
