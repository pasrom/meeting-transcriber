import CoreAudio
import Foundation

/// Live-buffer forwarding for `AppAudioCapture`. Extracted to a sibling file so
/// `AppAudioCapture.swift` stays under the 600-line lint cap; same pattern as
/// `AppAudioCapture+PIDTranslation.swift`.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Hand already-resampled 16 kHz mono samples to the optional live sink —
    /// the same data `writeCapturedBuffer` writes to the file fd. The normal
    /// path: forwarding the resampled buffer means the app side doesn't resample
    /// a second time (`LiveAudioResampler` short-circuits 16 kHz mono). Gap-fill
    /// silence is deliberately excluded; only the buffer's real samples flow
    /// here. Short-circuits when no sink is installed.
    func forwardToLiveSink(monoSamples: [Float]) {
        guard let sink = liveSink, !monoSamples.isEmpty else { return }
        sink(LiveAudioBuffer(
            samples: monoSamples,
            channelCount: 1,
            sampleRate: Int(speechSampleRate),
            hostTime: mach_absolute_time(),
        ))
    }

    /// Copy the interleaved float32 IOProc buffer into `[Float]` and hand it
    /// to the optional live sink at the raw device rate/channels. Fallback only:
    /// used when no resampler was built (`writeCapturedBuffer`'s `resampler ==
    /// nil` branch), so the live path still gets audio it can resample itself.
    /// Short-circuits when no sink is installed so the batch-only path stays
    /// allocation-free.
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
