import Foundation

/// Whether the app-audio tap has carried essentially nothing for two minutes:
/// at least 90% of its samples in buffers whose RMS is below one 16-bit step.
///
/// **Why this exists (issue #699).** A tap anchored where the meeting app does
/// not play delivered a constant floor of about -98.5 dBFS for a whole
/// 56-minute call. Never an exact zero, so every buffer counted as energy for
/// `ChannelSignalAges`, and the digital-silence report, which waits for a
/// window without energy, never came. A tap of a meeting app that is simply
/// silent delivers exact zeros, so a floor that sits below one step and never
/// rises is not a quiet far end: the tap is not reading the meeting app.
///
/// **Only a sensor, and only for the warning.** The energy definition the
/// level publisher, the microphone channel and the silent-track watchdog share
/// stays "any non-zero sample"; this type reads the same per-buffer sum of
/// squares beside it and reports one flag (see `ChannelFault.noiseFloor` for
/// how it is reported). Nothing here restarts or re-anchors the tap.
///
/// **What counts as zero.** Every sample of a buffer whose RMS is below
/// `stepRMS`, 2^-15 (about -90.3 dBFS), one step of the 16-bit tracks the
/// recording is written as. An all-zero buffer is below it too. Per buffer
/// rather than per sample, because a noise floor is not a level every sample
/// sits under: a per-sample threshold lets a floor just below the step through
/// on its peaks, while the buffer's RMS stays under it throughout.
///
/// **The thresholds** come from the exact-zero measurement made for a
/// proposed anchor search (PR #713): the largest share of zero samples in any
/// rolling 120-second window was 12.2% to 41.7% across 20 healthy recordings
/// and 98.7% to 100% across 6 dead ones. 90% sits in that empty gap. Those
/// counts were taken on the written 16-bit files, where a sample below half a
/// step reads as zero, so a buffer-level count against one step is close to
/// what was measured, not identical to it. The healthy ceiling is essentially
/// the longest idle stretch over the window (49.85 s / 120 s is 41.5%), so the
/// window is what keeps the gap open: at 60 s the healthy ceiling would rise
/// to about 83%. Clearing at 50% keeps a window hovering near the trip point
/// from flipping the flag buffer by buffer.
struct AppNoiseFloorSensor {
    /// One 16-bit step. A buffer below it counts as zero throughout.
    static let stepRMS: Double = 1.0 / 32768.0

    /// Share of zero samples over a full window at which the flag is raised.
    static let tripFraction = 0.90

    /// Share of zero samples at or below which a raised flag clears.
    static let clearFraction = 0.50

    /// Raised once a full window reached `tripFraction`, cleared once the
    /// rolling window falls to `clearFraction`.
    private(set) var isFloorOnly = false

    /// Samples pooled per second, so the memory is bounded by the window
    /// rather than by the buffer rate.
    private struct Bin {
        let second: Int
        var zeroSamples: Int
        var totalSamples: Int
    }

    private var bins: [Bin] = []
    /// Sums over `bins`, kept as they change rather than recounted per buffer.
    private var zeroSamples = 0
    private var totalSamples = 0

    /// Feed one captured buffer.
    /// - Parameters:
    ///   - sumOfSquares: the sum of the squared raw samples, which the capture
    ///     path's RMS loop already computes.
    ///   - samples: how many samples the buffer held.
    ///   - now: monotonic seconds.
    mutating func observe(sumOfSquares: Double, samples: Int, now: TimeInterval) {
        guard samples > 0 else { return }

        let rms = (sumOfSquares / Double(samples)).squareRoot()
        let zeros = rms < Self.stepRMS ? samples : 0
        let second = Int(now.rounded(.down))
        if let last = bins.indices.last, bins[last].second == second {
            bins[last].zeroSamples += zeros
            bins[last].totalSamples += samples
        } else {
            bins.append(Bin(second: second, zeroSamples: zeros, totalSamples: samples))
        }
        zeroSamples += zeros
        totalSamples += samples
        // A bin stays while any part of it can still fall inside the window.
        let oldestKept = Int((now - AppNoiseFloorLimits.windowSeconds).rounded(.down))
        while let first = bins.first, first.second < oldestKept {
            zeroSamples -= first.zeroSamples
            totalSamples -= first.totalSamples
            bins.removeFirst()
        }

        let fraction = Double(zeroSamples) / Double(totalSamples)
        if isFloorOnly {
            if fraction <= Self.clearFraction { isFloorOnly = false }
            return
        }
        // Every recording opens on a few buffers of nothing; a fraction over
        // a partly filled window is not what the thresholds were measured on.
        // Judged by what the window still holds, not by when the recording
        // began: after a gap in delivery it holds only what came since.
        guard let oldest = bins.first, oldest.second <= oldestKept else { return }
        if fraction >= Self.tripFraction { isFloorOnly = true }
    }
}

/// The sensor's window, public so the user-facing message can name it from
/// the same constant, the way `SilentTrackWatchdogLimits` serves the
/// watchdog's copy.
public enum AppNoiseFloorLimits {
    public static let windowSeconds: TimeInterval = 120
}
