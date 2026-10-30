@preconcurrency import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Guards that `AudioMixer.resampleFile` keeps the *content* of an import, not
/// just its shape.
///
/// Why this file exists: every audio fixture in `Tests/Fixtures/` is mono,
/// little-endian and carries no channel layout, and the one stereo file
/// (`two_speakers_de.ogg`) is the only one no `resampleFile` test ever routes
/// through the import path. The existing suite therefore asserts sample rate,
/// channel count and `length > 0` against inputs that cannot expose a decoder
/// swap: endianness, the stereo downmix law, a tagged channel layout and the
/// decoded-versus-container length are all unobservable with the fixtures we own.
///
/// Rather than commit more binary fixtures, the shapes that are missing are
/// synthesised here from `AVAudioFile` alone, except a lying container header,
/// which is byte-patched into a copy of a committed fixture (`MP4File`) because
/// no writer will produce one. The expected levels are arithmetic,
/// not recorded: a 440 Hz sine of amplitude `a` has RMS `a / sqrt(2)`, so the
/// assertions below are derived values with tolerance, not golden numbers.
final class AudioImportFidelityTests: XCTestCase {
    // MARK: - Content-preserving import

    /// AIFF stores PCM big-endian. A decoder that requests native-endian float
    /// without saying so reads the bytes byte-swapped, which turns a clean sine
    /// into full-scale noise while still reporting success.
    func testResampleFilePreservesLevelForBigEndianSource() async throws {
        let source = try makeStereoAIFF(amplitude: 0.5)
        let destination = makeTempFile(suffix: ".wav")

        try await AudioMixer.resampleFile(from: source, to: destination)

        let samples = try AudioMixer.loadAudioFileAsFloat32(url: destination)
        // L == R == 0.5 sine, so any correct downmix keeps amplitude 0.5.
        XCTAssertEqual(
            AudioMixer.rmsDecibels(samples: samples), -9.0, accuracy: 1.0,
            "a big-endian source must decode to the same level as a little-endian one",
        )
        XCTAssertLessThan(
            samples.map(abs).max() ?? 0, 0.95,
            "a 0.5-amplitude source must not reach full scale after import",
        )
    }

    /// The import folds stereo to mono by averaging the channels. A
    /// power-preserving fold (0.707 per channel) is ~3 dB louder and clips
    /// sources that the averaging fold leaves untouched.
    func testResampleFileAveragesStereoChannels() async throws {
        let source = try makeAsymmetricStereoWAV(left: 0.8, right: 0.4)
        let destination = makeTempFile(suffix: ".wav")

        try await AudioMixer.resampleFile(from: source, to: destination)

        let samples = try AudioMixer.loadAudioFileAsFloat32(url: destination)
        // (0.8 + 0.4) / 2 = 0.6 amplitude -> 0.6 / sqrt(2) = 0.424 RMS = -7.45 dBFS.
        XCTAssertEqual(
            AudioMixer.rmsDecibels(samples: samples), -7.45, accuracy: 1.0,
            "stereo must be folded by averaging the channels",
        )
    }

    /// `kAudioChannelLayoutTag_DiscreteInOrder` is what a multi-channel capture
    /// device reports. A downmix that does not understand the tag can emit
    /// digital silence and still report success.
    func testResampleFileDecodesDiscreteChannelLayout() async throws {
        let source = try makeDiscreteLayoutCAF(amplitude: 0.5)
        let destination = makeTempFile(suffix: ".wav")

        try await AudioMixer.resampleFile(from: source, to: destination)

        let samples = try AudioMixer.loadAudioFileAsFloat32(url: destination)
        XCTAssertGreaterThan(
            AudioMixer.rmsDecibels(samples: samples), -40,
            "a discrete channel layout must not decode to silence",
        )
    }

    // MARK: - Length comes from the audio, not from the container

    /// Fixtures whose sample rate differs from the pipeline target, so
    /// `resampleFile` decodes them instead of taking its byte-copy fast path.
    private static let fixturesRequiringDecode = [
        "sine_440hz_44k.m4a",
        "sine_440hz_44k.mp3",
        "two_speakers_de.opus",
        "synthetic_amrnb.amr",
        "synthetic_amrnb.3gp",
    ]

    /// The output must be as long as the audio that was actually decoded. A
    /// container's declared duration is an estimate for several formats, and
    /// pinning the output to it silently pads the tail with fabricated silence
    /// or truncates real audio, in both cases reporting success.
    func testResampleFileMatchesDecodedSourceDuration() async throws {
        for name in Self.fixturesRequiringDecode {
            let source = fixtureURL(name)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "Fixture \(name) not found")
            let destination = makeTempFile(suffix: ".wav")

            try await AudioMixer.resampleFile(from: source, to: destination)

            let sourceFile = try AVAudioFile(forReading: source)
            let outputFile = try AVAudioFile(forReading: destination)
            let decodedSeconds = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate
            let outputSeconds = Double(outputFile.length) / outputFile.processingFormat.sampleRate
            XCTAssertEqual(
                outputSeconds, decodedSeconds, accuracy: 0.02,
                "\(name): import length must follow the decoded audio, not the container's duration",
            )
        }
    }

    // MARK: - The import must terminate

    /// `two_speakers_de.ogg` is the repo's only stereo fixture and the only one
    /// no other `resampleFile` test covers. It is bounded explicitly because the
    /// failure this guards against is a decoder that blocks forever rather than
    /// erroring: nothing in `resampleFile` or `PipelineQueue` imposes a deadline,
    /// and cooperative cancellation cannot interrupt a blocking decode.
    func testResampleFileTerminatesForOggVorbis() async throws {
        let source = fixtureURL("two_speakers_de.ogg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "Fixture not found")
        let destination = makeTempFile(suffix: ".wav")

        let finished = expectation(description: "resampleFile returns")
        Task.detached {
            defer { finished.fulfill() }
            try? await AudioMixer.resampleFile(from: source, to: destination)
        }
        await fulfillment(of: [finished], timeout: 30)
        // The task is deliberately not awaited. In the case this guards against
        // it never completes, and awaiting it would hang the suite instead of
        // failing it -- cooperative cancellation cannot interrupt a blocking
        // decode either. A decode error surfaces below instead, as an output
        // file that cannot be opened.
        let outputFile = try AVAudioFile(forReading: destination)
        XCTAssertEqual(Int(outputFile.processingFormat.sampleRate), AudioConstants.targetSampleRate)
        XCTAssertGreaterThan(
            AudioMixer.rmsDecibels(forFileAt: destination) ?? -.infinity, -40,
            "the imported Ogg must carry speech, not silence",
        )
    }

    // MARK: - AVAsset fallback, called directly

    /// `loadAudioFromAVAsset` is tier 2 of `loadAudioAsFloat32`, reached only
    /// when `AVAudioFile` throws on a file that is not MKV/WebM. No fixture we
    /// own makes tier 1 throw, so these call tier 2 directly, the way
    /// `AudioMixerStreamingTests` calls `streamResampleFile`. Going through
    /// `resampleFile` would exercise tier 1 and see none of this.

    /// Bounded explicitly: the failure guarded against is a decoder that blocks
    /// forever rather than erroring. Nothing in `loadAudioAsFloat32` or
    /// `PipelineQueue` imposes a deadline.
    func testAVAssetFallbackTerminatesForOggVorbis() async throws {
        let source = fixtureURL("two_speakers_de.ogg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "Fixture not found")
        let destination = makeTempFile(suffix: ".wav")

        let finished = expectation(description: "loadAudioFromAVAsset returns")
        Task.detached {
            defer { finished.fulfill() }
            guard let decoded = try? await AudioMixer.loadAudioFromAVAsset(url: source) else { return }
            try? AudioMixer.saveWAV(
                samples: decoded.samples, sampleRate: decoded.sampleRate, url: destination,
            )
        }
        await fulfillment(of: [finished], timeout: 30)
        // Bound to the expectation only. Awaiting the task would deadlock the
        // suite instead of failing it, because a blocked `copyNextSampleBuffer`
        // never returns and cooperative cancellation cannot interrupt it. The
        // result travels out through the file instead.
        let outputFile = try AVAudioFile(forReading: destination)
        let sourceFile = try AVAudioFile(forReading: source)
        XCTAssertEqual(
            Double(outputFile.length) / outputFile.processingFormat.sampleRate,
            Double(sourceFile.length) / sourceFile.processingFormat.sampleRate,
            accuracy: 0.02,
            "a decode that stops early still reports success, so assert the whole track arrived",
        )
        XCTAssertGreaterThan(
            AudioMixer.rmsDecibels(forFileAt: destination) ?? -.infinity, -40,
            "the decoded Ogg must carry speech, not silence",
        )
    }

    /// Differential on purpose: it asserts the two byte orders agree, not an
    /// absolute level, so it stays valid whichever way the tier folds channels.
    func testAVAssetFallbackDecodesBigEndianLikeLittleEndian() async throws {
        let bigEndian = try makeStereoAIFF(amplitude: 0.5)
        let littleEndian = try makeAsymmetricStereoWAV(left: 0.5, right: 0.5)

        let fromBigEndian = try await AudioMixer.loadAudioFromAVAsset(url: bigEndian).samples
        let fromLittleEndian = try await AudioMixer.loadAudioFromAVAsset(url: littleEndian).samples

        XCTAssertEqual(
            AudioMixer.rmsDecibels(samples: fromBigEndian),
            AudioMixer.rmsDecibels(samples: fromLittleEndian),
            accuracy: 0.5,
            "byte order must not change the decoded level",
        )
        XCTAssertLessThan(
            fromBigEndian.map(abs).max() ?? 0, 0.95,
            "a 0.5-amplitude source must not reach full scale after decoding",
        )
    }

    /// Both tiers must fold channels the same way, or the level of an import
    /// depends on which one happened to open the file.
    func testAVAssetFallbackAveragesStereoChannelsLikeAVAudioFile() async throws {
        let source = try makeAsymmetricStereoWAV(left: 0.8, right: 0.4)

        let viaFallback = try await AudioMixer.loadAudioFromAVAsset(url: source).samples
        let viaAudioFile = try AudioMixer.loadAudioFileAsFloat32(url: source)

        XCTAssertEqual(
            AudioMixer.rmsDecibels(samples: viaFallback),
            AudioMixer.rmsDecibels(samples: viaAudioFile),
            accuracy: 0.5,
            "the AVAsset fallback must fold channels like AVAudioFile does",
        )
        // (0.8 + 0.4) / 2 = 0.6 amplitude -> 0.6 / sqrt(2) = -7.45 dBFS. Pinned
        // as well as the comparison, so both tiers being wrong the same way
        // cannot pass.
        XCTAssertEqual(
            AudioMixer.rmsDecibels(samples: viaFallback), -7.45, accuracy: 1.0,
            "stereo must be folded by averaging the channels",
        )
    }

    /// A tagged discrete layout decoding to silence is the worst shape of this
    /// bug: the job succeeds and the transcript is simply empty.
    func testAVAssetFallbackDecodesDiscreteChannelLayout() async throws {
        let source = try makeDiscreteLayoutCAF(amplitude: 0.5)

        let samples = try await AudioMixer.loadAudioFromAVAsset(url: source).samples

        XCTAssertGreaterThan(
            AudioMixer.rmsDecibels(samples: samples), -40,
            "a discrete channel layout must not decode to silence",
        )
    }

    /// A container that claims 4.29e9 seconds must decode normally, not size a
    /// buffer from the claim: see `sampleReservation` for why that aborts.
    /// (`AVAudioFile` happens to open this patched file, which is why it is fed
    /// to tier 2 directly.)
    ///
    /// The lie sits in the movie-timescale headers (`mvhd`, `tkhd`, `elst`)
    /// because those are what AVFoundation derives both the asset's and the
    /// track's duration from when an edit list is present. The same lie in
    /// `mdhd` alone reaches neither, and `mdhd`'s timescale also times the
    /// samples. The patch is not invisible to every reader, though: tier 1
    /// (`AVAudioFile`) reports about 130 fewer source frames for the patched
    /// copy, which is why the comparison below is between two tier-2 decodes.
    ///
    /// Without the guard this test does not fail, it aborts the test process
    /// on the allocation, since that crash is the regression it pins.
    func testAVAssetFallbackDecodesFileWhoseContainerClaimsAbsurdDuration() async throws {
        let source = fixtureURL("sine_440hz_44k.m4a")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "Fixture not found")
        let patched = try makeFileWithAbsurdContainerDuration(from: source)

        // Precondition, so the test cannot pass vacuously if AVFoundation ever
        // starts sanitising the header: both the asset and its audio track
        // claim the bogus span, whichever one a decoder sizes itself from.
        // Opened with the same precise-timing option the code under test uses.
        let asset = AVURLAsset(url: patched, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let assetSeconds = try await CMTimeGetSeconds(asset.load(.duration))
        let trackSeconds = try await CMTimeGetSeconds(track.load(.timeRange).duration)
        XCTAssertGreaterThan(assetSeconds, 1e9, "patched header must claim billions of seconds")
        XCTAssertGreaterThan(trackSeconds, 1e9, "patched header must claim billions of seconds")

        let expected = try await AudioMixer.loadAudioFromAVAsset(url: source).samples.count
        let samples = try await AudioMixer.loadAudioFromAVAsset(url: patched).samples

        XCTAssertEqual(samples.count, expected, "a lying container duration must not change what is decoded")
        // Pinned absolutely as well, so both decodes being wrong the same way
        // cannot pass: the fixture holds one second of audio.
        XCTAssertEqual(
            Double(samples.count) / Double(AudioConstants.targetSampleRate), 1.0, accuracy: 0.03,
            "the patched file must decode to the fixture's one second",
        )
        XCTAssertGreaterThan(
            AudioMixer.rmsDecibels(samples: samples), -40,
            "the decoded sine must carry signal, not silence",
        )
    }

    // MARK: - Byte-patched sources

    /// Copy `source` and rewrite its movie timescale to 1 and every
    /// movie-timescale duration (`mvhd`, `tkhd`, `elst` segment) to `0xFFFFFFFF`,
    /// leaving the media header and sample tables intact. Requires version-0
    /// boxes and one track with one non-empty edit, since the timescale
    /// rescales every such duration; throws otherwise rather than half-patch.
    private func makeFileWithAbsurdContainerDuration(from source: URL) throws -> URL {
        var file = try MP4File(contentsOf: source)
        let mvhd = try file.box(at: "moov", "mvhd")
        let tkhd = try file.box(at: "moov", "trak", "tkhd")
        let elst = try file.box(at: "moov", "trak", "edts", "elst")

        // Payload offset 0 holds the version (top byte) and flags.
        for box in [mvhd, tkhd, elst] where try file.uint32(atPayloadOffset: 0, in: box) >> 24 != 0 {
            throw MP4File.FormatError(description: "\(box.type) is not a version-0 box")
        }
        let entryCount = try file.uint32(atPayloadOffset: 4, in: elst)
        guard entryCount == 1 else {
            throw MP4File.FormatError(description: "expected one edit, found \(entryCount)")
        }
        guard try file.uint32(atPayloadOffset: 12, in: elst) != .max else {
            throw MP4File.FormatError(description: "the edit is empty (media time -1)")
        }

        try file.put(1, atPayloadOffset: 12, in: mvhd) // timescale
        try file.put(.max, atPayloadOffset: 16, in: mvhd) // duration
        try file.put(.max, atPayloadOffset: 20, in: tkhd) // duration (after times, track ID, reserved)
        try file.put(.max, atPayloadOffset: 8, in: elst) // first segment duration

        let url = makeTempFile(suffix: ".m4a")
        try file.data.write(to: url)
        return url
    }

    // MARK: - Synthesised sources

    /// Settings derived from an `AVAudioFormat` rather than hand-built: a literal
    /// dictionary that omits a key `ExtAudioFile` wants fails the file creation
    /// with a bare `fmt?` and no indication of which key is missing.
    private func writerSettings(rate: Double, channels: AVAudioChannelCount) throws -> [String: Any] {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: channels,
            interleaved: false,
        ))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        return settings
    }

    private func sine(frameCount: Int, rate: Double, amplitude: Float) -> [Float] {
        (0 ..< frameCount).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(rate)) }
    }

    private func write(
        _ url: URL, settings: [String: Any], rate: Double, seconds: Double,
        channelAmplitudes: [Float],
    ) throws {
        let frameCount = Int(rate * seconds)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount),
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for (channel, amplitude) in channelAmplitudes.enumerated() {
            let samples = sine(frameCount: frameCount, rate: rate, amplitude: amplitude)
            channelData[channel].update(from: samples, count: frameCount)
        }
        try file.write(from: buffer)
    }

    /// Stereo AIFF at 48 kHz. AIFF PCM is big-endian by definition, which is the
    /// property under test.
    private func makeStereoAIFF(amplitude: Float) throws -> URL {
        let url = makeTempFile(suffix: ".aiff")
        var settings = try writerSettings(rate: 48000, channels: 2)
        settings[AVLinearPCMIsBigEndianKey] = true
        try write(
            url,
            settings: settings,
            rate: 48000,
            seconds: 2,
            channelAmplitudes: [amplitude, amplitude],
        )
        return url
    }

    /// Stereo WAV whose channels differ, so the downmix law is observable. With
    /// identical channels a dropped, swapped or summed channel is invisible.
    private func makeAsymmetricStereoWAV(left: Float, right: Float) throws -> URL {
        let url = makeTempFile(suffix: ".wav")
        try write(
            url,
            settings: writerSettings(rate: 48000, channels: 2),
            rate: 48000,
            seconds: 2,
            channelAmplitudes: [left, right],
        )
        return url
    }

    /// CAF tagged `kAudioChannelLayoutTag_DiscreteInOrder`.
    private func makeDiscreteLayoutCAF(amplitude: Float) throws -> URL {
        let url = makeTempFile(suffix: ".caf")
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | 2
        var settings = try writerSettings(rate: 48000, channels: 2)
        settings[AVChannelLayoutKey] = Data(
            bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size,
        )
        try write(
            url,
            settings: settings,
            rate: 48000,
            seconds: 2,
            channelAmplitudes: [amplitude, amplitude],
        )
        return url
    }
}
