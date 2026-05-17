import Foundation
import os

/// Owns the cross-thread coordination for "audio callback writes the latest
/// per-buffer level, UI thread reads it at its own cadence." Each capture
/// handler (`AppAudioCapture`, `MicCaptureHandler`) holds one instance and
/// calls `publish(level:)` from inside its real-time audio callback.
///
/// Reads via `currentLevelDBFS` self-decay to silence (-120 dBFS) when no
/// publish has happened in the last `stalenessSec` — so a dead tap is
/// indistinguishable from real silence to downstream consumers, instead of
/// carrying a stale last-known value forever.
///
/// Today's impl uses `OSAllocatedUnfairLock`, which is *not* strictly
/// real-time-safe — priority inversion is possible under contention.
/// At 10 Hz UI poll the lock is uncontended ~99.99% of the time, so the
/// glitch probability is microscopic. Migration to lock-free `ManagedAtomic`
/// (swift-atomics) is tracked as a follow-up.
final class LevelPublisher {
    private let lock = OSAllocatedUnfairLock(initialState: LevelSlot())
    private let stalenessSec: Double

    init(stalenessSec: Double = 0.5) {
        self.stalenessSec = stalenessSec
    }

    /// Called from the audio callback after each buffer.
    func publish(level: Double) {
        let now = mach_absolute_time()
        lock.withLock { slot in
            slot.levelDBFS = level
            slot.lastUpdateTicks = now
        }
    }

    /// Reads the most recent level, returning -120 dBFS if stale.
    var currentLevelDBFS: Double {
        lock.withLock { slot in
            currentLevel(
                level: slot.levelDBFS,
                lastUpdateTicks: slot.lastUpdateTicks,
                nowTicks: mach_absolute_time(),
                stalenessSec: stalenessSec,
            )
        }
    }
}
