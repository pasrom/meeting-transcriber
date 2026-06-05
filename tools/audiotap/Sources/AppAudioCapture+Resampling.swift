@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Capture-time resampling for `AppAudioCapture`. Folds each CATap buffer to
/// 16 kHz mono before the file write (issue #379 follow-up) so a mid-recording
/// output-device rate change can't time-warp the track the way a single
/// post-hoc resample did. Extracted to a sibling file so `AppAudioCapture.swift`
/// stays under the 600-line lint cap — same pattern as
/// `AppAudioCapture+LiveSink.swift`.
@available(macOS 14.2, *)
public extension AppAudioCapture {
    /// Format of the data actually written to the output fd: 16 kHz mono when
    /// the resampler is active (the normal case), else the raw device input
    /// (`actualSampleRate`/`actualChannels`) as a fallback. Read by
    /// `AudioCaptureSession` to describe the produced file.
    var outputSampleRate: Int {
        resampler != nil ? Int(speechSampleRate) : actualSampleRate
    }

    var outputChannels: Int {
        resampler != nil ? 1 : actualChannels
    }

    /// The buffer's hardware presentation time in mach ticks, for wall-clock
    /// gap-filling. Falls back to the callback clock if the IOProc didn't mark
    /// the host time valid.
    internal static func hostTicks(from time: UnsafePointer<AudioTimeStamp>) -> UInt64 {
        let stamp = time.pointee
        return stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
    }

    /// Resample + downmix one interleaved CATap buffer to 16 kHz mono and write
    /// it to `fd`, rebuilding the converter on a mid-recording rate change. The
    /// resampler buffers internally, so a buffer that yields no output yet
    /// (converter priming) is simply not written — its samples emerge on a later
    /// call, no data lost. Falls back to the raw native-rate write only if no
    /// resampler was built (not expected for a 16 kHz target). `hostTicks` is the
    /// buffer's hardware presentation time, used to fill device-restart gaps with
    /// silence so the track stays aligned to wall-clock. Runs on `writeQueue`.
    internal func writeCapturedBuffer(
        fd: Int32, data: UnsafeMutableRawPointer, byteCount: Int, hostTicks: UInt64,
    ) {
        guard let resampler else {
            writeAllToFileHandle(fd, data, count: byteCount)
            return
        }
        let floatCount = byteCount / MemoryLayout<Float>.size
        let interleaved = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: floatCount,
        ))
        let mono16k = resampler.process(
            interleaved, inputRate: actualSampleRate, inputChannels: max(actualChannels, 1),
        )
        guard !mono16k.isEmpty else { return }
        fillTimelineGap(fd: fd, hostTicks: hostTicks, outputFrames: mono16k.count)
        Self.writeFloats(mono16k, to: fd)
    }

    /// Write silence for a device-restart gap before this buffer's audio, so the
    /// app track stays aligned to wall-clock (issue #379 follow-up). Mirrors
    /// `MicCaptureHandler.fillTimelineGap`; the `TimelineAnchor` self-anchors on
    /// the first buffer and is never reset, so only a real gap produces silence.
    private func fillTimelineGap(fd: Int32, hostTicks: UInt64, outputFrames: Int) {
        let silence = timelineAnchor.silenceFramesBefore(
            hostSeconds: machTicksToSeconds(hostTicks), frameCount: outputFrames,
        )
        guard silence > 0 else { return }
        Self.writeFloats([Float](repeating: 0, count: silence), to: fd)
    }

    /// Write a float buffer's raw bytes to `fd` in one POSIX write loop.
    private static func writeFloats(_ samples: [Float], to fd: Int32) {
        samples.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                writeAllToFileHandle(fd, base, count: raw.count)
            }
        }
    }
}
