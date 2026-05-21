import Foundation

/// A snapshot of audio samples delivered in real-time from a capture source.
///
/// Yielded synchronously from the audio callback (CATap IOProc for app audio,
/// AVAudioEngine input tap for mic). Sinks should treat this as a hot path:
/// enqueue the buffer onto an actor / AsyncStream and return — no blocking
/// work, no logging, no allocation beyond what's strictly required.
public struct LiveAudioBuffer: Sendable {
    /// PCM samples. Float32 in [-1, 1]. Interleaved when `channelCount > 1`.
    public let samples: [Float]

    /// Channels in `samples` (1 = mono, 2 = stereo interleaved L/R/L/R…).
    public let channelCount: Int

    /// Sample rate in Hz that produced these samples.
    public let sampleRate: Int

    /// `mach_absolute_time()` at the moment the callback fired. Useful for
    /// aligning multiple capture sources or measuring drift over a session.
    public let hostTime: UInt64

    public init(samples: [Float], channelCount: Int, sampleRate: Int, hostTime: UInt64) {
        self.samples = samples
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.hostTime = hostTime
    }
}

/// Closure invoked once per captured audio buffer. Called on the audio
/// callback thread — implementations must not block.
public typealias LiveAudioSink = @Sendable (LiveAudioBuffer) -> Void
