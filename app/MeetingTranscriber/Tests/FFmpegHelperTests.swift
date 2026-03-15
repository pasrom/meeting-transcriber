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

    // MARK: - Audio Loading from Fixtures (requires ffmpeg)

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

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
