import Foundation

/// Filename suffixes for the three audio files produced by a dual-source recording.
enum RecordingFileSuffix {
    static let mix = "_mix.wav"
    static let app = "_app.wav"
    static let mic = "_mic.wav"

    /// Written when a recording starts and removed when it stops, so a
    /// surviving one means the process died mid-recording.
    ///
    /// The raw app temp below carries the same meaning for a recording that
    /// taps an app, but only for those: a microphone-only recording (issue
    /// #633) opens no tap and writes no temp, so a crash left nothing to find
    /// and the audio was lost. This marker is source-independent.
    ///
    /// It must stay the ONLY new crash signal. "A mic track with no mix" looks
    /// like an interrupted recording and is in fact the normal end state of
    /// every processed one, since `AudioPersistencePolicy` moves the mix into
    /// the output folder and leaves the mic track in staging. Inferring a crash
    /// from that once re-processed 40 recordings on a live archive.
    static let inProgress = "_recording.marker"

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

    /// Strip the in-progress marker suffix, or nil when `filename` is not one.
    static func stripInProgress(from filename: String) -> String? {
        filename.hasSuffix(inProgress) ? String(filename.dropLast(inProgress.count)) : nil
    }

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
