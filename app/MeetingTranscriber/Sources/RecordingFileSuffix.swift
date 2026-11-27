import Foundation

/// Filename suffixes for the three audio files produced by a dual-source recording.
enum RecordingFileSuffix {
    static let mix = "_mix.wav"
    static let app = "_app.wav"
    static let mic = "_mic.wav"

    /// Where the mix is written before it is renamed to `mix`, so a `_mix.wav`
    /// only ever exists complete. The mix is what says a recording finished
    /// (crash recovery skips a stem that has one), and a write cut off by an
    /// exit, a quit whose budget ran out among them, must not leave a
    /// half-written one saying so. Deliberately not ending in `mix`, so no
    /// scan for finished mixes picks it up. Each write puts a unique token
    /// between the stem and this suffix (`writeMixAtomically`), and the
    /// cleanup after crash recovery removes what a cut-off write left.
    static let mixStaging = "_mix.partial.wav"

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

    /// The mute times of a recording still in progress, saved at each toggle so
    /// crash recovery can attach them. See `MicMuteLog`.
    static let micMuteLog = "_mic_mute.json"

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

    /// The stem and the track of a WAV track file name. WAV only on purpose:
    /// staging only ever holds WAV, and the scans that read it (orphan
    /// recovery, record-only) must not take a compressed file for a track.
    /// Readers of the output folder use `keptTrack(of:extensions:)`.
    static func stripSuffix(from filename: String) -> (stem: String, suffix: String)? {
        for suffix in all where filename.hasSuffix(suffix) {
            return (String(filename.dropLast(suffix.count)), suffix)
        }
        return nil
    }

    /// The container every track is recorded and staged in.
    static let wavExtension = "wav"

    /// The lossless container a finished recording's tracks may be converted
    /// to in the output folder (`RecordingCompaction`). Never written to staging.
    static let compressedExtension = "flac"

    /// The containers a track kept in the output folder can be in, WAV first.
    /// A reader that must find a kept track tries them in this order.
    static let keptExtensions = [wavExtension, compressedExtension]

    /// `suffix` (one of `all`) in the container `fileExtension`:
    /// `_mix.wav` becomes `_mix.flac`.
    static func kept(_ suffix: String, extension fileExtension: String) -> String {
        String(suffix.dropLast(wavExtension.count)) + fileExtension
    }

    /// The three track suffixes in the compressed container.
    static let compressed: [String] = all.map { kept($0, extension: compressedExtension) }

    /// The stem, the track and the container of a kept track's file name, for
    /// a name ending in one of `all` in one of `extensions`. The track comes
    /// back as its WAV suffix (`mix`, `app` or `mic`), so a caller tells the
    /// tracks apart without caring which container holds them. A hidden
    /// partial copy (`.<stem>_mix.partial.flac`) is no track: it does not end
    /// in a track suffix.
    static func keptTrack(
        of filename: String, extensions: [String] = keptExtensions,
    ) -> (stem: String, suffix: String, fileExtension: String)? {
        for suffix in all {
            for fileExtension in extensions {
                let spelling = kept(suffix, extension: fileExtension)
                if filename.hasSuffix(spelling) {
                    return (String(filename.dropLast(spelling.count)), suffix, fileExtension)
                }
            }
        }
        return nil
    }
}
