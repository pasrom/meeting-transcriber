import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "audio")

/// Per-buffer level + dBFS-energy logging helpers driven from the
/// CoreAudio IOProc. Extracted from `AppAudioCapture.swift` to keep the
/// main file under the 600-line lint cap; `levelPublisher`, `debugRMS`,
/// `debugTotalBytes`, and `debugLogging` are therefore `internal` rather
/// than `private` on the parent class.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Publish the most recent per-buffer dBFS reading so UI consumers
    /// (menu bar level indicator) can poll it. Called from the IOProc
    /// after `accumulateDebugRMS`.
    func publishCurrentLevel() {
        levelPublisher.publish(level: debugRMS.lastLevelDBFS)
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
