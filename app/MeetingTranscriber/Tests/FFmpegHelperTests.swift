@testable import MeetingTranscriber
import XCTest

final class FFmpegHelperTests: XCTestCase {
    // MARK: - Detection

    func testIsAvailableReflectsPath() {
        // isAvailable should be consistent with ffmpegPath
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

    // MARK: - Audio Loading (requires ffmpeg)

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    func testLoadAudioFromMKV() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        // Create an MKV from the existing WAV fixture using ffmpeg
        let wavURL = fixtureURL("two_speakers_de.wav")
        let mkvURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_ffmpeg_\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: mkvURL) }

        // Convert WAV → MKV via ffmpeg
        let ffmpegPath = try XCTUnwrap(FFmpegHelper.ffmpegPath)
        let convertProcess = Process()
        convertProcess.executableURL = URL(fileURLWithPath: ffmpegPath)
        convertProcess.arguments = [
            "-i", wavURL.path,
            "-c:a", "libvorbis",
            "-y", "-loglevel", "error",
            mkvURL.path,
        ]
        try convertProcess.run()
        convertProcess.waitUntilExit()
        XCTAssertEqual(convertProcess.terminationStatus, 0, "ffmpeg conversion to MKV failed")

        // Load via ffmpeg helper
        let (samples, sampleRate) = try await FFmpegHelper.loadAudioWithFFmpeg(url: mkvURL)
        XCTAssertEqual(sampleRate, 16000)
        XCTAssertGreaterThan(samples.count, 0, "Should extract audio samples from MKV")
    }

    func testLoadAudioAsFloat32FallsBackToFFmpeg() async throws {
        try XCTSkipUnless(FFmpegHelper.isAvailable, "ffmpeg not installed")

        // Create a WebM from the existing WAV fixture
        let wavURL = fixtureURL("two_speakers_de.wav")
        let webmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_fallback_\(UUID().uuidString).webm")
        defer { try? FileManager.default.removeItem(at: webmURL) }

        let ffmpegPath = try XCTUnwrap(FFmpegHelper.ffmpegPath)
        let convertProcess = Process()
        convertProcess.executableURL = URL(fileURLWithPath: ffmpegPath)
        convertProcess.arguments = [
            "-i", wavURL.path,
            "-c:a", "libvorbis",
            "-y", "-loglevel", "error",
            webmURL.path,
        ]
        try convertProcess.run()
        convertProcess.waitUntilExit()
        XCTAssertEqual(convertProcess.terminationStatus, 0, "ffmpeg conversion to WebM failed")

        // Load via the main entry point — should fall through AVAudioFile → AVAsset → ffmpeg
        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: webmURL)
        XCTAssertEqual(sampleRate, 16000)
        XCTAssertGreaterThan(samples.count, 0, "Full fallback chain should extract audio from WebM")
    }
}
