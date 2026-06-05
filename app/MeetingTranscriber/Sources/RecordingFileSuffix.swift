import Foundation

/// Filename suffixes for the three audio files produced by a dual-source recording.
enum RecordingFileSuffix {
    static let mix = "_mix.wav"
    static let app = "_app.wav"
    static let mic = "_mic.wav"

    /// Raw float32 app-audio temp file written live during capture (16 kHz
    /// mono, in-IOProc resampled) and consumed by `buildRecording` at `stop()`.
    /// A leftover one means the writer was killed mid-recording (crash) — see
    /// `recoverCrashedRecordings`. The suffix encodes the content format: the
    /// temp is headerless, so crash recovery across an app upgrade can only
    /// tell formats apart by name.
    static let appRaw = "_app16k_raw.tmp"

    /// Temp suffix written by versions before the capture-time resampler: raw
    /// interleaved float32 at the DEVICE's native rate/channels (typically
    /// 48 kHz stereo). Never written anymore — only read by crash recovery (so
    /// an upgrade doesn't turn a pre-upgrade crash's audio into 6×-slowed
    /// garbage) and deleted by temp cleanup.
    static let legacyAppRaw = "_app_raw.tmp"

    /// Both raw-temp suffixes, current format first — the probe order used by
    /// crash recovery and temp cleanup.
    static let appRawAny: [String] = [appRaw, legacyAppRaw]

    static let all: [String] = [mix, app, mic]

    /// Stem of a raw app temp filename (either format); nil for other files.
    static func stripAppRaw(from filename: String) -> String? {
        for suffix in appRawAny where filename.hasSuffix(suffix) {
            return String(filename.dropLast(suffix.count))
        }
        return nil
    }

    static func stripSuffix(from filename: String) -> (stem: String, suffix: String)? {
        for suffix in all where filename.hasSuffix(suffix) {
            return (String(filename.dropLast(suffix.count)), suffix)
        }
        return nil
    }
}
