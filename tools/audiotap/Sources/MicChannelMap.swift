import AVFoundation

/// Decides when a multi-channel mic input needs an EXPLICIT converter
/// `channelMap` instead of `AVAudioConverter`'s implicit downmix.
///
/// Why this exists: `AVAudioConverter` silently produces **silence** (all-zero
/// downmix matrix, `convert` returns success, no error) for most layouts a real
/// capture device reports. The built-in mic switches from 1ch to a 3ch discrete
/// array as soon as another app activates voice processing (a WeChat /
/// FaceTime / Teams call), so the mic track of a whole call is written as
/// digital silence while the app track records normally.
///
/// The set of layouts the implicit path folds correctly is much smaller than
/// "everything that is not discrete". Measured on macOS 26.5.2, 48 kHz → 16 kHz
/// mono, 0.5-amplitude sine on *every* input channel:
///
///     mono; stereo with no layout; kAudioChannelLayoutTag_Stereo    0.5  ok
///     DiscreteInOrder 2ch / 3ch / 4ch                               0.0  silent
///     StereoHeadphones, MatrixStereo, MidSide, XY, Binaural         0.0  silent
///
/// `MidSide` and `XY` are microphone-pair configurations, so the silent set is
/// not exotic. The policy is therefore an ALLOWLIST: only layouts measured to
/// fold correctly stay on the implicit path, everything else selects one real
/// channel. A named surround layout loses its correct fold that way, but no mic
/// input reports one, and one audible channel beats a silent track.
///
/// For a mic array channel 0 is taken as-is rather than averaging the elements,
/// which would risk comb filtering from the inter-element delay.
public enum MicChannelMap {
    // `AVAudioConverter.channelMap` takes `[NSNumber]`, and `nil` here means
    // "leave the converter's own downmix alone" rather than "map no channels",
    // so both of these rules are unavoidable at this boundary.
    // swiftlint:disable discouraged_optional_collection legacy_objc_type

    /// `[0]` when `format` needs an explicit single-channel selection, `nil`
    /// when the implicit downmix is trustworthy.
    public static func downmixMap(for format: AVAudioFormat) -> [NSNumber]? {
        guard format.channelCount > 1 else { return nil }

        guard let layout = format.channelLayout else {
            // Plain stereo carries no layout object and folds L+R correctly.
            return format.channelCount == 2 ? nil : [0]
        }

        if format.channelCount == 2, layout.layoutTag == kAudioChannelLayoutTag_Stereo {
            return nil
        }
        return [0]
    }

    // swiftlint:enable discouraged_optional_collection legacy_objc_type
}
