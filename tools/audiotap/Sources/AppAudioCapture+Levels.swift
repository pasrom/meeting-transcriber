import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Publish the most recent per-buffer dBFS reading to the lock-protected
    /// slot so UI consumers (menu bar level indicator) can poll it.
    /// Called from the IOProc after `accumulateDebugRMS`.
    func publishCurrentLevel() {
        let level = debugRMS.lastLevelDBFS
        let now = mach_absolute_time()
        levelLock.withLock { slot in
            slot.levelDBFS = level
            slot.lastUpdateTicks = now
        }
    }

    /// Sums squares of the interleaved Float32 buffer into the shared RMS reporter.
    /// Called unconditionally from the IOProc; the dBFS log line is gated separately.
    func accumulateDebugRMS(data: UnsafeMutableRawPointer, byteCount: Int) {
        let count = byteCount / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let buf = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: count,
        )
        var sumSq: Double = 0
        for sample in buf {
            sumSq += Double(sample) * Double(sample)
        }
        debugRMS.add(sumSq: sumSq, samples: count)
        debugTotalBytes += UInt64(byteCount)
    }

    /// Drain the 5-s throttle and emit one RMS-energy log line per tick, but
    /// only when `debugLogging` is on. The drain itself runs unconditionally
    /// so the reporter's accumulators stay bounded for long sessions.
    func maybeReportDebugRMS() {
        guard let report = debugRMS.tick() else { return }
        guard debugLogging else { return }
        let dBStr = String(format: "%.1f", report.dBFS)
        logger.info(
            "[debug] App audio RMS (5s): \(dBStr, privacy: .public) dBFS, samples=\(report.samples, privacy: .public), totalBytes=\(self.debugTotalBytes, privacy: .public)",
        )
    }
}
