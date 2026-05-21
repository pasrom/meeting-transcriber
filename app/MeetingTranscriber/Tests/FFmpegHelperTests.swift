@testable import MeetingTranscriber
import XCTest

final class FFmpegHelperTests: XCTestCase {
    // MARK: - Detection

    func testIsAvailableReflectsPath() {
        XCTAssertEqual(FFmpegHelper.isAvailable, FFmpegHelper.ffmpegPath != nil)
    }

    func testFFmpegOnlyTypesNotEmpty() {
        XCTAssertFalse(FFmpegHelper.ffmpegOnlyTypes.isEmpty)
        let extensions = FFmpegHelper.ffmpegOnlyTypes.compactMap(\.preferredFilenameExtension)
        XCTAssertTrue(extensions.contains("mkv"))
        XCTAssertTrue(extensions.contains("webm"))
        XCTAssertTrue(extensions.contains("ogg"))
    }

    // MARK: - Error Descriptions

    func testFFmpegNotAvailableError() {
        let error = AudioMixerError.ffmpegNotAvailable
        XCTAssertEqual(error.errorDescription, "ffmpeg not found. Install: brew install ffmpeg")
    }

    func testFFmpegFailedError() {
        let error = AudioMixerError.ffmpegFailed("No such file")
        XCTAssertEqual(error.errorDescription, "ffmpeg failed: No such file")
    }

    // MARK: - detectFFmpegPath

    func testDetectFFmpegPathReturnsEnvVarWhenSet() {
        // FFMPEG_BINARY takes precedence over searchPaths. The env path
        // is honored verbatim — no normalization or canonicalization.
        let result = FFmpegHelper.detectFFmpegPath(
            environment: ["FFMPEG_BINARY": "/opt/custom/ffmpeg"],
            searchPaths: ["/opt/homebrew/bin"],
        ) { $0 == "/opt/custom/ffmpeg" }
        XCTAssertEqual(result, "/opt/custom/ffmpeg")
    }

    func testDetectFFmpegPathSkipsEnvVarWhenNotExecutable() {
        // Env-var path that doesn't exist / isn't executable falls through
        // to the search-path cascade so a stale value doesn't break detection.
        let result = FFmpegHelper.detectFFmpegPath(
            environment: ["FFMPEG_BINARY": "/nonexistent/ffmpeg"],
            searchPaths: ["/opt/homebrew/bin"],
        ) { $0 == "/opt/homebrew/bin/ffmpeg" }
        XCTAssertEqual(result, "/opt/homebrew/bin/ffmpeg")
    }

    func testDetectFFmpegPathReturnsFirstSearchPathHit() {
        // Search-path order matters: the first executable hit wins, even
        // if later paths would also resolve.
        let result = FFmpegHelper.detectFFmpegPath(
            environment: [:],
            searchPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"],
        ) { path in
            path == "/opt/homebrew/bin/ffmpeg" || path == "/usr/local/bin/ffmpeg"
        }
        XCTAssertEqual(result, "/opt/homebrew/bin/ffmpeg")
    }

    func testDetectFFmpegPathFallsThroughToLaterSearchPath() {
        let result = FFmpegHelper.detectFFmpegPath(
            environment: [:],
            searchPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"],
        ) { $0 == "/usr/local/bin/ffmpeg" }
        XCTAssertEqual(result, "/usr/local/bin/ffmpeg")
    }

    func testDetectFFmpegPathReturnsNilWhenNothingFound() {
        let result = FFmpegHelper.detectFFmpegPath(
            environment: [:],
            searchPaths: ["/a", "/b", "/c"],
        ) { _ in false }
        XCTAssertNil(result)
    }

    func testDetectFFmpegPathIgnoresEmptySearchPathList() {
        // No env-var, empty search list → nil. The cascade must not crash
        // or return a default.
        let result = FFmpegHelper.detectFFmpegPath(
            environment: [:],
            searchPaths: [],
        ) { _ in true }
        XCTAssertNil(result)
    }

    func testDetectFFmpegPathEmptyEnvVarFallsThrough() {
        // Empty string is a key-present case but not a real path; the
        // isExecutable check rejects it so the cascade continues.
        let result = FFmpegHelper.detectFFmpegPath(
            environment: ["FFMPEG_BINARY": ""],
            searchPaths: ["/opt/homebrew/bin"],
        ) { $0 == "/opt/homebrew/bin/ffmpeg" }
        XCTAssertEqual(result, "/opt/homebrew/bin/ffmpeg")
    }

    // MARK: - buildConversionArguments

    func testBuildConversionArgumentsHasCorrectShape() {
        // Use a non-default sample rate so this test also pins that the
        // `-ar` slot is parameterized, not baked.
        let input = URL(fileURLWithPath: "/tmp/in.mkv")
        let output = URL(fileURLWithPath: "/tmp/out.wav")
        let args = FFmpegHelper.buildConversionArguments(input: input, output: output, sampleRate: 48000)
        XCTAssertEqual(args, [
            "-i", "/tmp/in.mkv",
            "-vn",
            "-ac", "1",
            "-ar", "48000",
            "-f", "wav",
            "/tmp/out.wav",
            "-y",
            "-loglevel", "error",
        ])
    }

    func testBuildConversionArgumentsPassesPathsThroughUnquoted() {
        // Process handles argv quoting; the helper must NOT pre-quote. A
        // path with spaces flows through verbatim.
        let input = URL(fileURLWithPath: "/tmp/has spaces.mkv")
        let output = URL(fileURLWithPath: "/tmp/out file.wav")
        let args = FFmpegHelper.buildConversionArguments(input: input, output: output, sampleRate: 16000)
        XCTAssertTrue(args.contains("/tmp/has spaces.mkv"))
        XCTAssertTrue(args.contains("/tmp/out file.wav"))
    }

    // MARK: - makeFFmpegFailureError

    func testMakeFFmpegFailureErrorWrapsTrimmedStderr() {
        let err = FFmpegHelper.makeFFmpegFailureError(
            stderrData: Data("  Unsupported codec\n".utf8),
        )
        guard case let .ffmpegFailed(stderr) = err else {
            XCTFail("Expected .ffmpegFailed, got \(err)")
            return
        }
        XCTAssertEqual(stderr, "Unsupported codec")
    }

    func testMakeFFmpegFailureErrorEmptyStderrPassesThrough() {
        let err = FFmpegHelper.makeFFmpegFailureError(stderrData: Data())
        guard case let .ffmpegFailed(stderr) = err else {
            XCTFail("Expected .ffmpegFailed, got \(err)")
            return
        }
        XCTAssertEqual(stderr, "")
    }

    func testMakeFFmpegFailureErrorInvalidUTF8FallsBackToEmpty() {
        let invalid = Data([0xFF, 0xFE, 0xFD])
        let err = FFmpegHelper.makeFFmpegFailureError(stderrData: invalid)
        guard case let .ffmpegFailed(stderr) = err else {
            XCTFail("Expected .ffmpegFailed, got \(err)")
            return
        }
        XCTAssertEqual(stderr, "")
    }

    // MARK: - Audio Loading from Fixtures (requires ffmpeg)

    func testLoadAudioFromMKV() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        let (samples, sampleRate) = try await FFmpegHelper.loadAudioWithFFmpeg(url: fixtureURL("two_speakers_de.mkv"))
        XCTAssertEqual(sampleRate, 16000)
        // ~15s speech at 16kHz ≈ 240000 samples
        XCTAssertGreaterThan(samples.count, 200_000)
    }

    func testLoadAudioFromWebM() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        let (samples, sampleRate) = try await FFmpegHelper.loadAudioWithFFmpeg(url: fixtureURL("two_speakers_de.webm"))
        XCTAssertEqual(sampleRate, 16000)
        XCTAssertGreaterThan(samples.count, 200_000)
    }

    func testLoadAudioFromOGG() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        let (samples, sampleRate) = try await FFmpegHelper.loadAudioWithFFmpeg(url: fixtureURL("two_speakers_de.ogg"))
        XCTAssertEqual(sampleRate, 16000)
        XCTAssertGreaterThan(samples.count, 200_000)
    }

    // MARK: - Full Fallback Chain (AVAudioFile → AVAsset → ffmpeg)

    func testLoadAudioAsFloat32FallsBackToFFmpegForMKV() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: fixtureURL("two_speakers_de.mkv"))
        XCTAssertEqual(sampleRate, 16000)
        XCTAssertGreaterThan(samples.count, 200_000)
    }

    func testLoadAudioAsFloat32FallsBackToFFmpegForWebM() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: fixtureURL("two_speakers_de.webm"))
        XCTAssertEqual(sampleRate, 16000)
        XCTAssertGreaterThan(samples.count, 200_000)
    }

    // MARK: - Audio Quality

    func testFFmpegExtractedAudioHasEnergy() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        let (samples, _) = try await FFmpegHelper.loadAudioWithFFmpeg(url: fixtureURL("two_speakers_de.mkv"))
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        XCTAssertGreaterThan(rms, 0.01, "Extracted speech audio should not be silent")
    }

    func testMKVAndWAVProduceSimilarDuration() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        let (wavSamples, wavRate) = try await AudioMixer.loadAudioAsFloat32(url: fixtureURL("two_speakers_de.wav"))
        let (mkvSamples, mkvRate) = try await AudioMixer.loadAudioAsFloat32(url: fixtureURL("two_speakers_de.mkv"))

        let wavDuration = Double(wavSamples.count) / Double(wavRate)
        let mkvDuration = Double(mkvSamples.count) / Double(mkvRate)
        XCTAssertEqual(wavDuration, mkvDuration, accuracy: 0.5, "MKV should preserve original duration")
    }
}
