import UniformTypeIdentifiers

/// File types offered by the two `NSOpenPanel` import pickers: batch file import
/// and voice enrollment.
///
/// Phone and messenger voice formats sit in the unconditional list because
/// AudioToolbox reads them natively — `.amr`, `.3gp`/`.3g2` (AMR or AAC payload)
/// and Ogg (`.opus`/`.ogg`/`.oga`) all open through `AVAudioFile` — so ffmpeg is
/// merely the last tier of `AudioMixer.loadAudioAsFloat32`'s fallback chain for
/// them, never a precondition. Only `FFmpegHelper.ffmpegOnlyTypes` (MKV/WebM)
/// genuinely needs the CLI and stays gated on it being installed.
///
/// Types are resolved from file extensions rather than written as UTI identifier
/// strings, because `UTType(_:)` is failable and a wrong identifier is dropped
/// silently by `compactMap` — removing the format from the panel with no build
/// error.
enum AudioImportTypes {
    /// 3GPP containers, named wherever they are wanted because they conform to
    /// `.audiovisualContent` only — an `.audio` filter hides them, and they are
    /// what a smartphone call recording arrives as.
    private static let phoneContainerExtensions = ["3gp", "3g2"]

    /// Extensions with no compile-time `UTType` constant. `"opus"` resolves to
    /// `org.xiph.ogg-audio`, which covers `.ogg` and `.oga` as well.
    private static let extraNativeExtensions = ["amr", "opus"]

    /// Audio and video types readable without the ffmpeg CLI.
    private static let nativeTypes: [UTType] = [
        .wav, .mp3, .aiff, .mpeg4Audio, .mpeg4Movie, .quickTimeMovie,
    ] + (extraNativeExtensions + phoneContainerExtensions).compactMap { UTType(filenameExtension: $0) }

    /// Types for the batch import panel (⌘P).
    static func pickerTypes(ffmpegAvailable: Bool) -> [UTType] {
        nativeTypes + (ffmpegAvailable ? FFmpegHelper.ffmpegOnlyTypes : [])
    }

    /// Types for the voice-enrollment panel, which takes a single speech sample.
    /// `.audio` already covers most audio formats, `.amr` and `.opus` included.
    static let enrollmentTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav]
        + phoneContainerExtensions.compactMap { UTType(filenameExtension: $0) }
}
