import Foundation

/// Returns the most recent dBFS reading, falling back to silence (-120 dBFS) if no
/// update has happened within `stalenessSec`. Used to make per-channel level readings
/// self-decay to silence when the audio callback stops delivering buffers (e.g. tap
/// died, device unplugged) — without that, a stale reading would look like live
/// speech to downstream consumers.
///
/// Pure function so the freshness math is unit-testable without sleeping or mocking
/// the mach clock.
func currentLevel(
    level: Double,
    lastUpdateTicks: UInt64,
    nowTicks: UInt64,
    stalenessSec: Double,
) -> Double {
    if lastUpdateTicks == 0 { return -120 }
    let ageSec = machTicksToSeconds(nowTicks - lastUpdateTicks)
    return ageSec > stalenessSec ? -120 : level
}
