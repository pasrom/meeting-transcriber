@preconcurrency import AVFoundation

/// The tap → WAV converter for one mic capture, plus whether an explicit
/// channel selection had to be applied (for logging).
public struct MicConverterSetup {
    public let converter: AVAudioConverter
    /// Non-nil when `MicChannelMap` required an explicit single-channel
    /// selection because the implicit downmix would have written silence.
    public let selectedChannel: Int?
}

/// Builds the converter that folds the mic tap format to the 16 kHz mono WAV.
///
/// Separated from `MicCaptureHandler` so the channel-map decision is testable
/// without an audio device: the handler only reaches this code with a live
/// engine, yet the failure it guards against (a discrete layout downmixing to
/// digital silence) is a pure property of the format.
public enum MicConverterFactory {
    /// `nil` when the tap already matches the file format and no conversion is
    /// needed. Otherwise a converter configured for this tap format, with an
    /// explicit `channelMap` whenever the implicit downmix cannot be trusted.
    public static func make(tapFormat: AVAudioFormat, fileSampleRate: Double) -> MicConverterSetup? {
        // Convert whenever the tap isn't already at the file format — this
        // covers resampling AND downmixing a multi-channel input device. Since
        // the tap matches the node's real channel count (issue #379), a 2ch
        // device is captured as 2ch and folded to the mono WAV here.
        guard tapFormat.sampleRate != fileSampleRate || tapFormat.channelCount != 1 else { return nil }
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: fileSampleRate, channels: 1),
              let converter = AVAudioConverter(from: tapFormat, to: outputFormat)
        else { return nil }

        // AVAudioConverter's IMPLICIT downmix writes SILENCE — with no error —
        // for every layout but plain stereo, and a mic array reports exactly
        // such a layout. The built-in mic switches to a 3ch discrete array the
        // moment another app activates voice processing (any WeChat / FaceTime
        // / Teams call), so the mic track of a real call recorded 50 minutes of
        // digital silence while the app track was fine. See `MicChannelMap`.
        guard let map = MicChannelMap.downmixMap(for: tapFormat) else {
            return MicConverterSetup(converter: converter, selectedChannel: nil)
        }
        converter.channelMap = map
        return MicConverterSetup(converter: converter, selectedChannel: map.first?.intValue)
    }
}
