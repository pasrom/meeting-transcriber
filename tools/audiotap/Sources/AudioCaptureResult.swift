import Foundation

/// Result returned by `AudioCaptureSession.stop()`.
public struct AudioCaptureResult: Sendable {
    /// URL of the raw app audio file (interleaved float32 PCM).
    public let appAudioFileURL: URL
    /// URL of the mic audio WAV file (nil if mic was not recorded).
    public let micAudioFileURL: URL?
    /// Actual sample rate of the aggregate device (may differ from requested).
    public let actualSampleRate: Int
    /// Actual channel count of the app audio (1=mono, 2=stereo).
    public let actualChannels: Int
    /// Time delta between app and mic first frames (seconds, positive = mic started later).
    public let micDelay: TimeInterval
}
