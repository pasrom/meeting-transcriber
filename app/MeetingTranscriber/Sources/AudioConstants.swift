/// Shared audio pipeline constants.
///
/// Note: `tools/audiotap/Sources/Helpers.swift` defines a matching
/// `speechSampleRate` constant for use within the AudioTapLib package.
enum AudioConstants {
    /// Target sample rate for speech recognition (WhisperKit).
    static let targetSampleRate = 16000
}
