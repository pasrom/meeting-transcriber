@preconcurrency import AVFoundation

/// Pure derivation of the mic tap format from the live hardware format.
/// Separated from MicCaptureHandler so the issue #379 invariant — the tap
/// MUST match the node's channel count (a hardcoded 1-channel tap raised an
/// NSException on a multi-channel device) — is unit-testable without hardware.
public enum TapFormatResolver {
    /// The tap format matching the node's bus — i.e. the node's own
    /// `outputFormat` — or nil when the hardware reported an invalid
    /// (0 Hz / 0-channel) format, the transient a device change can briefly
    /// expose. Returning the node's own format (rather than reconstructing a
    /// `standardFormatWithSampleRate:channels:`) is both correct and robust:
    /// it always matches the bus (issue #379 — a mismatched channel count made
    /// installTapOnBus raise) AND it works for any channel count, whereas
    /// `standardFormatWithSampleRate:channels:` returns nil for >2 channels
    /// (no inferable layout). The converter downmixes it to the mono WAV.
    public static func tapFormat(forHardware hwFormat: AVAudioFormat) -> AVAudioFormat? {
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { return nil }
        return hwFormat
    }
}
