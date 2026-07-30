import AVFoundation

/// Decides when a multi-channel mic input needs an EXPLICIT converter
/// `channelMap` instead of `AVAudioConverter`'s implicit downmix.
///
/// Why this exists: `AVAudioConverter` silently produces **silence** (all-zero
/// downmix matrix, `convert` returns success, no error) when the input format
/// carries a *discrete* channel layout — the layout a microphone array reports.
/// The built-in mic switches from 1ch to a 3ch discrete array as soon as any
/// other app activates voice processing (a WeChat / FaceTime / Teams call), so
/// the mic track of a real call is written as digital silence while the app
/// track records normally. Measured on macOS 26.1: discrete 2ch/3ch/4ch → peak
/// 0.0; the same conversion with `channelMap = [0]` → the input signal intact.
///
/// Standard mono/stereo layouts downmix correctly and are left alone, so a
/// normal stereo interface keeps both channels folded together as before.
public enum MicChannelMap {
    /// High 16 bits of a layout tag hold the tag "family"; the low 16 hold the
    /// channel count for count-parameterised tags such as `DiscreteInOrder`.
    private static let tagFamilyMask: AudioChannelLayoutTag = 0xFFFF_0000

    private static func family(of tag: AudioChannelLayoutTag) -> AudioChannelLayoutTag {
        tag & tagFamilyMask
    }

    /// `[0]` when `format` needs an explicit single-channel selection, `nil`
    /// when the implicit downmix is trustworthy (mono, or a standard layout
    /// with an inferable downmix matrix).
    public static func downmixMap(for format: AVAudioFormat) -> [NSNumber]? {
        guard format.channelCount > 1 else { return nil }

        guard let layout = format.channelLayout else {
            // No layout at all: only mono/stereo have an inferable downmix.
            return format.channelCount > 2 ? [0] : nil
        }

        let tagFamily = family(of: layout.layoutTag)
        let discreteFamily = family(of: kAudioChannelLayoutTag_DiscreteInOrder)
        let unknownFamily = family(of: kAudioChannelLayoutTag_Unknown)

        if tagFamily == discreteFamily || tagFamily == unknownFamily {
            return [0]
        }
        // Any other named layout above stereo has no meaningful mono fold for a
        // mic capture either — prefer one real channel over a guess.
        return format.channelCount > 2 ? [0] : nil
    }
}
