import CoreAudio
import Foundation

/// Live-buffer forwarding for `AppAudioCapture`. Extracted to a sibling file so
/// `AppAudioCapture.swift` stays under the 600-line lint cap; same pattern as
/// `AppAudioCapture+PIDTranslation.swift`.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Copy the interleaved float32 IOProc buffer into `[Float]` and hand it
    /// to the optional live sink. Short-circuits when no sink is installed so
    /// the batch-only path stays allocation-free.
    func forwardToLiveSink(data: UnsafeMutableRawPointer, byteCount: Int) {
        guard let sink = liveSink else { return }
        let sampleCount = byteCount / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }
        let buf = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: sampleCount,
        )
        let samples = Array(buf)
        let channelCount = max(actualChannels, 1)
        let rate = actualSampleRate > 0 ? actualSampleRate : sampleRate
        sink(LiveAudioBuffer(
            samples: samples,
            channelCount: channelCount,
            sampleRate: rate,
            hostTime: mach_absolute_time(),
        ))
    }
}
