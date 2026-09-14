import Foundation

/// What fraction of the samples in the last `windowSeconds` were exactly zero.
///
/// Split from `SilentTapWatchdog` so the windowing is testable apart from the
/// decision it feeds, and because `AnchorDeliveryCredit` needs the same
/// measurement over a different span.
///
/// Samples are accumulated into fixed-width bins and bins older than the window
/// are dropped, which bounds the memory at `windowSeconds / binSeconds` entries
/// regardless of buffer rate — a plain list of buffers would hold about 5,600
/// entries for a two-minute window at production cadence.
struct RollingZeroFraction: Equatable {
    let windowSeconds: TimeInterval
    let binSeconds: TimeInterval

    private struct Bin: Equatable {
        let index: Int
        var zeroSamples: Int
        var totalSamples: Int
    }

    private var bins: [Bin] = []
    /// When accumulation began, so a partly-filled window can be told from a
    /// full one. A fraction over half a window is not comparable to the
    /// measurements that set the threshold.
    private var firstObservation: TimeInterval?

    init(windowSeconds: TimeInterval, binSeconds: TimeInterval = 1) {
        self.windowSeconds = windowSeconds
        self.binSeconds = binSeconds
    }

    mutating func add(zeroSamples: Int, totalSamples: Int, now: TimeInterval) {
        guard totalSamples > 0 else { return }
        if firstObservation == nil { firstObservation = now }

        let index = Int((now / binSeconds).rounded(.down))
        if var last = bins.last, last.index == index {
            last.zeroSamples += zeroSamples
            last.totalSamples += totalSamples
            bins[bins.count - 1] = last
        } else {
            bins.append(Bin(index: index, zeroSamples: zeroSamples, totalSamples: totalSamples))
        }

        // A bin is kept while any part of it can still fall inside the window.
        let oldestKept = Int(((now - windowSeconds) / binSeconds).rounded(.down))
        bins.removeAll { $0.index < oldestKept }
    }

    /// How long has been observed since accumulation began, capped at the
    /// window. `nil` before anything has been observed at all.
    func span(now: TimeInterval) -> TimeInterval? {
        firstObservation.map { min(now - $0, windowSeconds) }
    }

    /// Fraction of observed samples that were exactly zero, or `nil` when
    /// nothing has been observed.
    var zeroFraction: Double? {
        let total = bins.reduce(0) { $0 + $1.totalSamples }
        guard total > 0 else { return nil }
        let zero = bins.reduce(0) { $0 + $1.zeroSamples }
        return Double(zero) / Double(total)
    }

    var totalSamples: Int {
        bins.reduce(0) { $0 + $1.totalSamples }
    }

    /// Drop everything observed so far. Used when the tap is torn down: the
    /// buffers a new tap delivers must not be pooled with the dead tap's.
    mutating func reset() {
        bins.removeAll()
        firstObservation = nil
    }
}
