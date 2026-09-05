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
        levelPublisher.publish(level: debugRMS.lastLevelDBFS, hasEnergy: debugRMS.lastBufferHadEnergy)
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

    /// Drain the 5-s throttle and act on it.
    ///
    /// Two consumers ride the same tick because `tick()` resets the
    /// accumulators, so only one caller can have it: the RMS log line, which is
    /// gated on `debugLogging`, and the silent-track observer, which is not
    /// (issue #672) because a track that went to zeroes has to be triageable
    /// without the user having turned verbose logging on beforehand. The drain
    /// itself runs unconditionally so the accumulators stay bounded.
    ///
    /// `processes` comes from the session whose IOProc is delivering these
    /// buffers, not from a field, so a block that outlives its own attempt
    /// cannot report about a tap it does not belong to. Required rather than
    /// defaulted: an empty list is a real state (a session built by a test seam
    /// has none) and a default would let a new call site reach it by accident.
    func maybeReportDebugRMS(processes: [TappedProcess]) {
        guard let report = debugRMS.tick() else { return }
        observeSilentTrack(processes: processes)
        guard debugLogging else { return }
        let dBStr = String(format: "%.1f", report.dBFS)
        logger.info(
            "[debug] App audio RMS (5s): \(dBStr, privacy: .public) dBFS, samples=\(report.samples, privacy: .public), totalBytes=\(self.debugTotalBytes, privacy: .public)",
        )
    }
}
