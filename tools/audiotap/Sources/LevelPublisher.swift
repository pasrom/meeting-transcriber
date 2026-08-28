import Foundation
import os

/// Lock-protected slot holding the most recent per-buffer level reading and the
/// mach tick at which it was written. Stored inside `OSAllocatedUnfairLock` in
/// `LevelPublisher` so reads (UI thread) and writes (audio thread) coordinate.
struct LevelSlot {
    var levelDBFS: Double = -120
    var lastUpdateTicks: UInt64 = 0

    /// Stamp of the last buffer that carried any signal. Advanced by a subset
    /// of the writes that advance `lastUpdateTicks`, so the gap between the two
    /// is exactly "how long this channel has been delivering nothing but
    /// zeroes".
    var lastEnergyTicks: UInt64 = 0
}

/// Owns the cross-thread coordination for "audio callback writes the latest
/// per-buffer level, UI thread reads it at its own cadence." Each capture
/// handler (`AppAudioCapture`, `MicCaptureHandler`) holds one instance and
/// calls `publish(level:)` from inside its audio callback path.
///
/// Reads via `currentLevelDBFS` self-decay to silence (-120 dBFS) when no
/// publish has happened in the last `stalenessSec` — so a dead tap is
/// indistinguishable from real silence to downstream consumers, instead of
/// carrying a stale last-known value forever.
///
/// **Thread context note:** the two production callers are not equivalent.
/// `AppAudioCapture` dispatches its IOProc work onto a serial GCD writer
/// queue (`audiotap.writer`, userInteractive QoS) and calls `publish` from
/// there — that's a regular GCD worker, not the real-time CoreAudio thread.
/// `MicCaptureHandler` installs its tap directly on `AVAudioEngine.inputNode`
/// and calls `publish` from the engine's render thread, which *is*
/// real-time-bound. `OSAllocatedUnfairLock` is the closest primitive Apple
/// ships for "briefly-held lock that's safe-ish under priority inversion";
/// the lock holds for two field writes (microseconds at worst). At 10 Hz UI
/// poll the lock is uncontended ~99.99% of the time, so the practical glitch
/// probability is microscopic. Migration to lock-free `ManagedAtomic` via
/// swift-atomics is tracked as a follow-up.
final class LevelPublisher: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: LevelSlot())
    private let stalenessSec: Double

    init(stalenessSec: Double = 0.5) {
        self.stalenessSec = stalenessSec
    }

    /// Called from the audio callback after each buffer. `hasEnergy` says
    /// whether this buffer carried any signal, which the level alone cannot
    /// convey (see `ChannelSignalAges`).
    func publish(level: Double, hasEnergy: Bool) {
        let now = mach_absolute_time()
        lock.withLock { slot in
            slot.levelDBFS = level
            slot.lastUpdateTicks = now
            if hasEnergy {
                slot.lastEnergyTicks = now
            }
        }
    }

    /// How long ago this channel last delivered a buffer, and last delivered
    /// one carrying signal. Unlike `currentLevelDBFS` this does not decay to a
    /// floor: the reader gets the raw ages and decides what a given gap means.
    var currentSignalAges: ChannelSignalAges {
        // Sampled and computed outside the lock, the way `publish` already
        // does: two loads is a far shorter hold than a clock read plus four
        // tick conversions, on a lock the render thread takes per buffer.
        let now = mach_absolute_time()
        let (updateTicks, energyTicks) = lock.withLock { slot in
            (slot.lastUpdateTicks, slot.lastEnergyTicks)
        }
        return signalAges(lastUpdateTicks: updateTicks, lastEnergyTicks: energyTicks, nowTicks: now)
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
