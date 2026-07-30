import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Characterization tests for the phone/messenger voice formats: AMR (raw and
/// inside 3GP), AAC-in-3GP, and Ogg Opus.
///
/// These do **not** pin the picker change — `.amr`/`.3gp`/`.opus` were never in
/// `FFmpegHelper.ffmpegOnlyExtensions`, so `loadAudioAsFloat32` took the native
/// path before it too. What they pin is the platform capability the feature rests
/// on: that Apple's frameworks decode these without the ffmpeg CLI, and that the
/// true source rate survives the import (AMR is 8 kHz, so a pipeline assuming
/// 16 kHz would transcribe at double speed). If a future macOS withdraws native
/// support, these go red and the format has to be gated on ffmpeg again.
final class VoiceFormatImportTests: XCTestCase {
    /// Decodes `fixture` and asserts rate, duration, and that it is not silent.
    ///
    /// Runs the file through the *synchronous* loader first, which is
    /// AVAudioFile-only and therefore structurally unable to reach ffmpeg — that
    /// is the nativeness proof. It returns no sample rate, so the rate assertion
    /// comes from `loadAudioAsFloat32`.
    private func assertDecodesNatively(
        _ fixture: String, expectedRate: Int, expectedDuration: Double, expectSpeech: Bool,
        file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        let url = fixtureURL(fixture)
        let viaAVAudioFileOnly = try AudioMixer.loadAudioFileAsFloat32(url: url)
        XCTAssertFalse(viaAVAudioFileOnly.isEmpty, "\(fixture) needs ffmpeg to decode", file: file, line: line)

        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: url)
        XCTAssertEqual(sampleRate, expectedRate, file: file, line: line)
        XCTAssertEqual(
            Double(samples.count) / Double(sampleRate), expectedDuration, accuracy: 0.2,
            "decoded duration must match the fixture", file: file, line: line,
        )
        if expectSpeech {
            XCTAssertGreaterThan(
                AudioMixer.rmsDecibels(samples: samples), -40,
                "speech fixture must not decode to silence", file: file, line: line,
            )
        }
    }

    // MARK: - Native decode, no ffmpeg

    func testOpusDecodesNatively() async throws {
        // Ogg support in AudioToolbox is undocumented (there is no public
        // `kAudioFileOggType`), so its introduction date is unknown and this
        // asserts only on the OS where native decode was measured. AMR and 3GPP
        // ride on long-standing public file types and are asserted everywhere.
        guard #available(macOS 26, *) else {
            throw XCTSkip("native Ogg decode measured on macOS 26; older systems fall back to ffmpeg")
        }
        try await assertDecodesNatively(
            "two_speakers_de.opus", expectedRate: 48000, expectedDuration: 5, expectSpeech: true,
        )
    }

    func testThreeGPWithAACDecodesNatively() async throws {
        try await assertDecodesNatively(
            "two_speakers_de.3gp", expectedRate: 16000, expectedDuration: 5, expectSpeech: true,
        )
    }

    /// The codec smartphone call recorders actually write. Distinct from the
    /// AAC-in-3GP case above: same container, different payload, decoded by a
    /// different AudioToolbox codec. Comfort-noise fixture, so no speech check.
    func testThreeGPWithAMRDecodesNatively() async throws {
        try await assertDecodesNatively(
            "synthetic_amrnb.3gp", expectedRate: 8000, expectedDuration: 3, expectSpeech: false,
        )
    }

    func testRawAMRDecodesNatively() async throws {
        try await assertDecodesNatively(
            "synthetic_amrnb.amr", expectedRate: 8000, expectedDuration: 3, expectSpeech: false,
        )
    }

    // MARK: - Rate handling on import

    /// The import path resamples with the rate the decoder reported, so a
    /// narrowband source lands at the pipeline's 16 kHz with twice the samples. A
    /// regression that hard-codes the source rate would keep the length and
    /// transcribe at double speed.
    func testResampleFileUpsamplesNarrowbandAMR() async throws {
        let source = fixtureURL("synthetic_amrnb.amr")
        let (sourceSamples, sourceRate) = try await AudioMixer.loadAudioAsFloat32(url: source)
        XCTAssertEqual(sourceRate, 8000)

        let destination = makeTempFile(suffix: ".wav")
        try await AudioMixer.resampleFile(from: source, to: destination)

        let resampled = try AVAudioFile(forReading: destination)
        XCTAssertEqual(Int(resampled.processingFormat.sampleRate), AudioConstants.targetSampleRate)
        XCTAssertEqual(
            Double(resampled.length), Double(sourceSamples.count) * 2, accuracy: Double(sourceRate),
            "8 kHz → 16 kHz must double the sample count",
        )
    }

    /// A source already at the target rate takes `resampleFile`'s copy fast path,
    /// so a 16 kHz 3GP is passed through verbatim under a `*.wav` name. Pinned
    /// because the mislabeling is invisible until something starts trusting the
    /// extension instead of sniffing content — every consumer opens audio through
    /// AVAudioFile today, which is what makes it survivable.
    func testFastPathPassesNonWAVSourceThroughUnderWAVName() async throws {
        let source = fixtureURL("two_speakers_de.3gp")
        let destination = makeTempFile(suffix: ".wav")
        try await AudioMixer.resampleFile(from: source, to: destination)

        XCTAssertEqual(
            try Data(contentsOf: destination), try Data(contentsOf: source),
            "a source already at 16 kHz must be copied verbatim, not re-encoded",
        )
        XCTAssertFalse(
            try AudioMixer.loadAudioFileAsFloat32(url: destination).isEmpty,
            "the mislabeled copy must stay decodable for downstream stages",
        )
    }
}
