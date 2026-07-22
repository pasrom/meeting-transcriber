import Foundation

/// Pure RMS-based "is this WAV non-silent?" analysis. Splits the samples into
/// non-overlapping windows, reports overall + peak-window loudness and the
/// fraction of windows above the threshold, plus a silence verdict. No file
/// I/O — the `wav-verdict` subcommand loads samples via AVAudioFile and hands
/// them here, so the decision logic stays deterministically unit-testable.
///
/// `activeWindowRatio` is what distinguishes a genuine continuous recording
/// from a "1 s blip then silence" regression: a driver asserting a sustained
/// tone checks both `!isSilent` and `activeWindowRatio` above a floor.
struct WavVerdict: Codable, Equatable {
    let overallRMSdBFS: Double
    let peakWindowRMSdBFS: Double
    let activeWindowRatio: Double
    let windowCount: Int
    let isSilent: Bool

    /// Loudness reported instead of -inf for digital silence, so the verdict
    /// stays JSON-encodable (JSON has no infinity).
    static let silenceFloorDBFS = -120.0

    static func analyze(
        samples: [Float],
        sampleRate: Double,
        windowSeconds: Double = 0.5,
        thresholdDBFS: Double = -50,
    ) -> Self {
        let windowSize = max(1, Int(windowSeconds * sampleRate))
        // Even a clip shorter than one window is analyzed as a single window.
        let windows = stride(from: 0, to: max(samples.count, 1), by: windowSize).map { start -> Double in
            let end = min(start + windowSize, samples.count)
            return dBFS(rmsOf: samples[start ..< end])
        }
        let peak = windows.max() ?? silenceFloorDBFS
        // Plain loop rather than filter().count / count(where:) — the latter
        // trip the SwiftFormat preferCountWhere vs SwiftLint trailing_closure
        // disagreement.
        var activeCount = 0
        for windowDBFS in windows where windowDBFS > thresholdDBFS {
            activeCount += 1
        }
        let ratio = windows.isEmpty ? 0 : Double(activeCount) / Double(windows.count)
        return Self(
            overallRMSdBFS: dBFS(rmsOf: samples[...]),
            peakWindowRMSdBFS: peak,
            activeWindowRatio: ratio,
            windowCount: windows.count,
            // Silent iff no window is loud enough — the peak decides it.
            isSilent: peak < thresholdDBFS,
        )
    }

    private static func dBFS(rmsOf samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return silenceFloorDBFS }
        var sumSquares = 0.0
        for sample in samples {
            sumSquares += Double(sample) * Double(sample)
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return silenceFloorDBFS }
        return max(silenceFloorDBFS, 20 * Foundation.log10(rms))
    }
}
