@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCaptureTimeline")

/// Wall-clock gap-filling for `MicCaptureHandler`. A device-change restart drops
/// mic audio for the teardown→rebuild gap; without compensation the WAV
/// under-runs and drifts out of sync with the app track (issue #379 follow-up).
/// Extracted to a sibling file so `MicCaptureHandler.swift` stays under the
/// 600-line lint cap — same pattern as `AppAudioCapture+Resampling.swift`.
extension MicCaptureHandler {
    /// Write silence for the gap before `outputFrames` of real audio, so the
    /// output file stays aligned to wall-clock. `when` is the buffer's hardware
    /// presentation time (jitter-free); falls back to the callback clock if the
    /// host time is invalid. The `TimelineAnchor` self-anchors on the first
    /// buffer and bridges restart gaps (it is never reset), so steady-state
    /// capture inserts nothing and only a real gap produces silence.
    func fillTimelineGap(before when: AVAudioTime, outputFrames: Int) {
        let hostTicks = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        let hostSeconds = machTicksToSeconds(hostTicks)
        let silence = timelineAnchor.silenceFramesBefore(
            hostSeconds: hostSeconds, frameCount: outputFrames,
        )
        guard silence > 0, let outputFile else { return }
        Self.writeSilence(frames: silence, to: outputFile)
    }

    /// A steady clock skew (mic crystal a little slower than the mach clock)
    /// back-fills a handful of frames every few seconds. Logging each one buries
    /// the export in noise, so only fills at or above this duration get a line.
    static let gapFillLogMinSeconds = 0.05

    /// Whether a gap fill of `frames` at `sampleRate` is large enough to log.
    /// Sub-threshold fills are the harmless clock-skew slivers; at or above it
    /// the gap is long enough to be a genuine restart worth one line. Pure so it
    /// can be unit-tested without touching a file or an engine.
    static func shouldLogGapFill(frames: Int, sampleRate: Double) -> Bool {
        Double(frames) >= sampleRate * gapFillLogMinSeconds
    }

    /// Write `frames` zeroed frames to `file` in its processing format. Static
    /// (engine-free) so it can be unit-tested directly against an `AVAudioFile`
    /// without any engine setup.
    static func writeSilence(frames: Int, to file: AVAudioFile) {
        guard frames > 0, let silentBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frames),
        ) else { return }
        silentBuffer.frameLength = AVAudioFrameCount(frames)
        // AVAudioPCMBuffer storage isn't guaranteed zeroed — clear it.
        if let channel = silentBuffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: frames)
        }
        do {
            try file.write(from: silentBuffer)
            if shouldLogGapFill(frames: frames, sampleRate: file.processingFormat.sampleRate) {
                logger.info("Mic: inserted \(frames) silent frames to keep the track aligned to wall-clock")
            }
        } catch {
            logger.warning("Mic timeline gap-fill write error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
