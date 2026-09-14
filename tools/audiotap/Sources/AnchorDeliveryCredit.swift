import Foundation

/// Decides when an anchor has carried enough real audio to be remembered as
/// last-known-good.
///
/// **Why this is not simply "a nonzero buffer arrived".** That was the first
/// version, and it is wrong in the exact case the anchor search exists for. A
/// 44.7-minute call whose app track was 98% silence still contained stray
/// energy — 55 of its 530 five-second windows were not -120 dBFS — so a single
/// nonzero sample would have recorded the dead anchor as known-good. The search
/// would then have offered that anchor first on the next failure, and the
/// memory meant to rescue the recording would have pointed back at the device
/// that lost it.
///
/// Credit therefore uses the same fractional notion as `SilentTapWatchdog`: an
/// anchor qualifies when a completed interval is *substantially* non-silent,
/// not when one sample sneaks through.
///
/// **Why the threshold is well below the watchdog's.** These are not mirror
/// images and must not be tuned as if they were. The watchdog asks "is this
/// anchor dead", where the populations sit at 41.7% and 98.7% zeros with a wide
/// gap. Credit asks "has this anchor demonstrably worked", and the interesting
/// input is the stray energy inside a dead track: distributing that call's 1.9%
/// nonzero samples across the 10.4% of its windows that held any energy leaves
/// those windows about 82% zeros. A credit threshold of 50% rejects them with
/// room to spare, while a healthy anchor — one actually carrying a conversation
/// — clears it many times a minute.
///
/// The interval is short because credit should be quick: an anchor that works
/// ought to be remembered long before the two-minute window the watchdog needs
/// to condemn one. Five seconds matches both the existing RMS reporting cadence
/// and the granularity of the field measurements above.
struct AnchorDeliveryCredit: Equatable {
    /// Longest share of exactly-zero samples an interval may hold and still
    /// count as delivery.
    static let defaultMaxZeroFraction = 0.50

    /// How much audio one verdict is formed over.
    static let defaultIntervalSeconds: TimeInterval = 5

    let maxZeroFraction: Double
    let intervalSeconds: TimeInterval

    private var window: RollingZeroFraction
    private var intervalStart: TimeInterval?

    init(
        maxZeroFraction: Double = Self.defaultMaxZeroFraction,
        intervalSeconds: TimeInterval = Self.defaultIntervalSeconds,
    ) {
        self.maxZeroFraction = maxZeroFraction
        self.intervalSeconds = intervalSeconds
        window = RollingZeroFraction(windowSeconds: intervalSeconds)
    }

    /// Feed one captured buffer.
    ///
    /// - Returns: true when a completed interval was substantially non-silent,
    ///   meaning the current anchor has earned its place in the search's memory.
    ///   Each interval answers at most once; the caller's own write is
    ///   idempotent per anchor, so a repeat costs nothing either way.
    mutating func observe(
        zeroSamples: Int, samples: Int, now: TimeInterval,
    ) -> Bool {
        guard samples > 0 else { return false }
        window.add(zeroSamples: zeroSamples, totalSamples: samples, now: now)
        guard let start = intervalStart else {
            intervalStart = now
            return false
        }
        guard now - start >= intervalSeconds else { return false }

        let fraction = window.zeroFraction ?? 1
        // Start the next interval either way. A verdict is about the audio that
        // has just been heard, so carrying stale samples forward would let one
        // good stretch keep crediting an anchor that has since gone quiet.
        intervalStart = now
        window.reset()
        return fraction <= maxZeroFraction
    }

    /// Abandon the interval in progress. Called when the tap is torn down, for
    /// the same reason the watchdog drops its window: buffers from a new tap
    /// must not be pooled with the previous anchor's.
    mutating func reset() {
        window.reset()
        intervalStart = nil
    }
}
