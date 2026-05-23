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

    /// A `public` struct's synthesized memberwise init is only `internal`, so
    /// other modules can't construct one — declare it `public` to complete the
    /// type's public API. (Lets the app's test target build fixtures directly.)
    public init(
        appAudioFileURL: URL,
        micAudioFileURL: URL?,
        actualSampleRate: Int,
        actualChannels: Int,
        micDelay: TimeInterval,
    ) {
        self.appAudioFileURL = appAudioFileURL
        self.micAudioFileURL = micAudioFileURL
        self.actualSampleRate = actualSampleRate
        self.actualChannels = actualChannels
        self.micDelay = micDelay
    }
}
