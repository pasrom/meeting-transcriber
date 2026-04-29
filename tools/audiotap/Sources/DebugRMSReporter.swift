import Foundation

/// Throttled RMS accumulator/reporter shared by the app-audio and mic-capture debug
/// logging paths. Caller feeds in pre-computed sum-of-squares + sample count;
/// `tick(intervalSeconds:)` returns a (dBFS, samples) snapshot at most once per
/// interval and resets the accumulators each time it fires.
struct DebugRMSReporter {
    var accumulator: Double = 0
    var sampleCount: Int = 0
    private var nextReportTicks: UInt64 = 0

    mutating func add(sumSq: Double, samples: Int) {
        accumulator += sumSq
        sampleCount += samples
    }

    /// Returns (dBFS, samples) when at least `intervalSeconds` have elapsed since the
    /// previous report (or first call); otherwise nil.
    mutating func tick(intervalSeconds: Double = 5.0) -> (dBFS: Double, samples: Int)? {
        let now = mach_absolute_time()
        if nextReportTicks == 0 {
            nextReportTicks = now + secondsToMachTicks(intervalSeconds)
            return nil
        }
        guard now >= nextReportTicks else { return nil }
        let dBFS: Double
        if sampleCount > 0 {
            let meanSq = accumulator / Double(sampleCount)
            let rms = meanSq > 0 ? sqrt(meanSq) : 0
            dBFS = rms > 0 ? 20 * log10(rms) : -120
        } else {
            dBFS = -120
        }
        let snapshot = (dBFS: dBFS, samples: sampleCount)
        accumulator = 0
        sampleCount = 0
        nextReportTicks = now + secondsToMachTicks(intervalSeconds)
        return snapshot
    }
}
