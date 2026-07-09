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
            logger.info("Mic: filled \(frames) silent frames for a device-restart gap")
        } catch {
            logger.warning("Mic timeline gap-fill write error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
