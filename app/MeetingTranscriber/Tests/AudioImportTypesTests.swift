@testable import MeetingTranscriber
import UniformTypeIdentifiers
import XCTest

/// Pins which file types the two import pickers offer. The pickers themselves
/// are `NSOpenPanel`s and therefore manual-QA-only, so these tests guard the one
/// thing that can silently regress: a type that fails to resolve drops out of
/// the list without a build error. That is how `.flac` and every phone voice
/// format ended up unselectable.
final class AudioImportTypesTests: XCTestCase {
    /// Extensions the import picker must accept with no ffmpeg installed,
    /// because `AVAudioFile` decodes them natively. `.amr`/`.3gp`/`.3g2` are what
    /// phone call recorders write, `.opus`/`.oga` what messengers and voice
    /// recorders write.
    private let nativeExtensions = [
        "wav", "mp3", "m4a", "mp4", "mov", "aiff", "flac",
        "amr", "3gp", "3g2", "opus", "ogg", "oga",
    ]

    /// Asserts `ext` maps to a UTType the panel would accept, i.e. one of `types`
    /// is the file's own type or an ancestor of it. `NSOpenPanel` enables a file
    /// when its type conforms to any allowed type, so plain `contains` would
    /// under-report (`.m4a` is `com.apple.m4a-audio`, which conforms to the
    /// listed `public.mpeg-4-audio`).
    private func assertAccepted(
        _ ext: String, by types: [UTType], _ picker: String,
        file: StaticString = #filePath, line: UInt = #line,
    ) throws {
        let type = try XCTUnwrap(
            UTType(filenameExtension: ext), "\(ext) has no UTType on this OS", file: file, line: line,
        )
        XCTAssertTrue(
            types.contains { type.conforms(to: $0) },
            "\(ext) (\(type.identifier)) is not selectable in the \(picker) picker",
            file: file, line: line,
        )
    }

    // MARK: - Import picker

    func testImportPickerAcceptsNativeFormatsWithoutFFmpeg() throws {
        let types = AudioImportTypes.pickerTypes(ffmpegAvailable: false)
        for ext in nativeExtensions {
            try assertAccepted(ext, by: types, "import")
        }
    }

    /// MKV/WebM are the only containers Apple's frameworks genuinely cannot read
    /// (verified: `AVAudioFile` fails with error 1954115647), so they stay gated
    /// on the CLI being installed.
    func testImportPickerGatesMKVAndWebMOnFFmpeg() throws {
        let withoutFFmpeg = AudioImportTypes.pickerTypes(ffmpegAvailable: false)
        let withFFmpeg = AudioImportTypes.pickerTypes(ffmpegAvailable: true)
        for ext in ["mkv", "webm"] {
            let type = try XCTUnwrap(UTType(filenameExtension: ext))
            XCTAssertFalse(
                withoutFFmpeg.contains { type.conforms(to: $0) },
                "\(ext) needs ffmpeg, so it must not be offered when the CLI is missing",
            )
            try assertAccepted(ext, by: withFFmpeg, "import")
        }
    }

    /// `.opus` resolves to the same declared type as `.ogg` and `.oga`
    /// (`org.xiph.ogg-audio`) on current macOS. If a future release splits it
    /// into its own type, listing only the ogg type would silently stop
    /// accepting `.opus` again.
    func testOpusIsCoveredEvenIfAppleSplitsItFromOgg() throws {
        try assertAccepted("opus", by: AudioImportTypes.pickerTypes(ffmpegAvailable: false), "import")
    }

    /// An unresolvable extension yields a *dynamic* placeholder type rather than
    /// nil, so the voice formats must map to real system types instead. Stock
    /// macOS declares each of these in `CoreTypes.bundle`, which is what makes
    /// the assertion machine-independent.
    ///
    /// Deliberately scoped to the formats this list owns. `.mkv` is excluded
    /// because CoreTypes declares no Matroska type at all — it resolves only on
    /// machines where something like VLC declares it, and is otherwise dynamic.
    /// That predates this list (`FFmpegHelper.ffmpegOnlyTypes` has always built
    /// it from the extension) and asserting on it would only encode whether the
    /// test machine happens to have a media player installed.
    func testVoiceFormatsMapToSystemDeclaredTypes() throws {
        for ext in ["amr", "3gp", "3g2", "flac", "opus", "ogg", "oga"] {
            let type = try XCTUnwrap(UTType(filenameExtension: ext))
            XCTAssertFalse(
                type.isDynamic,
                "\(ext) resolved to the placeholder \(type.identifier) instead of a declared type",
            )
        }
    }

    // MARK: - Voice enrollment picker

    /// Enrollment seeds the speaker DB from a single voice sample, and a phone
    /// call recording is a prime source. `public.3gpp` does not conform to
    /// `.audio`, so an `.audio`-only filter hides `.3gp` files.
    func testEnrollmentPickerAcceptsPhoneRecordings() throws {
        for ext in ["wav", "m4a", "mp3", "amr", "3gp", "3g2", "opus"] {
            try assertAccepted(ext, by: AudioImportTypes.enrollmentTypes, "voice enrollment")
        }
    }
}
