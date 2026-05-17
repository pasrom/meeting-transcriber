import Foundation

/// Lock-protected slot holding the most recent per-buffer level reading and the
/// mach tick at which it was written. Stored inside `OSAllocatedUnfairLock` in
/// the capture handlers so reads (UI thread) and writes (audio thread) coordinate.
struct LevelSlot {
    var levelDBFS: Double = -120
    var lastUpdateTicks: UInt64 = 0
}
