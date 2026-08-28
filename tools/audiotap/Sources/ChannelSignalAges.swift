import Foundation

/// How long ago a capture channel last delivered a buffer, and how long ago it
/// last delivered one that carried any signal at all.
///
/// The single dBFS reading the level path publishes cannot tell three states
/// apart, and they call for three different reactions:
///
/// - a buffer arrived carrying signal: the channel is healthy, however quiet;
/// - a buffer arrived carrying nothing but zeroes: the device or the system
///   muted it, or a gate closed in front of it, but the transport is alive;
/// - no buffer arrived at all: the transport itself stopped.
///
/// `DebugRMSReporter` reports the second as -120 dBFS and `currentLevel`
/// reports the third as the very same -120, while a real but extremely quiet
/// buffer can compute to *less* than -120 through the int16 path. So the
/// distinction has to be recorded where every buffer passes, not derived from a
/// level that is sampled at whatever rate the reader happens to poll.
///
/// `nil` means "never", which is not the same as "a long time ago": a channel
/// that has been muted since the recording began has no last-energy instant to
/// measure from.
public struct ChannelSignalAges: Equatable, Sendable {
    public let secondsSinceLastBuffer: Double?
    public let secondsSinceLastEnergy: Double?

    public init(secondsSinceLastBuffer: Double?, secondsSinceLastEnergy: Double?) {
        self.secondsSinceLastBuffer = secondsSinceLastBuffer
        self.secondsSinceLastEnergy = secondsSinceLastEnergy
    }

    /// A channel that was never opened. Distinct from one that was opened and
    /// has since gone quiet, which carries a buffer age.
    public static let unknown = Self(secondsSinceLastBuffer: nil, secondsSinceLastEnergy: nil)
}

/// Pure age arithmetic, split out from `LevelPublisher` for the same reason
/// `currentLevel` is: so the freshness maths is unit-testable without mocking
/// the mach clock.
func signalAges(lastUpdateTicks: UInt64, lastEnergyTicks: UInt64, nowTicks: UInt64) -> ChannelSignalAges {
    ChannelSignalAges(
        secondsSinceLastBuffer: elapsedSeconds(since: lastUpdateTicks, now: nowTicks),
        secondsSinceLastEnergy: elapsedSeconds(since: lastEnergyTicks, now: nowTicks),
    )
}

/// Seconds between two mach tick readings, or nil when the earlier one was
/// never taken. Clamps rather than underflows if the clock hands back a `now`
/// that precedes the stamp.
private func elapsedSeconds(since ticks: UInt64, now nowTicks: UInt64) -> Double? {
    guard ticks != 0 else { return nil }
    guard nowTicks > ticks else { return 0 }
    return machTicksToSeconds(nowTicks - ticks)
}
