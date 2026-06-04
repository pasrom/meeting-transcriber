import Foundation

/// Filename suffixes for the three audio files produced by a dual-source recording.
enum RecordingFileSuffix {
    static let mix = "_mix.wav"
    static let app = "_app.wav"
    static let mic = "_mic.wav"

    /// Raw interleaved-float32 app-audio temp file written live during capture
    /// and consumed by `buildRecording` at `stop()`. A leftover one means the
    /// writer was killed mid-recording (crash) — see `recoverCrashedRecordings`.
    static let appRaw = "_app_raw.tmp"

    static let all: [String] = [mix, app, mic]

    static func stripSuffix(from filename: String) -> (stem: String, suffix: String)? {
        for suffix in all where filename.hasSuffix(suffix) {
            return (String(filename.dropLast(suffix.count)), suffix)
        }
        return nil
    }
}
