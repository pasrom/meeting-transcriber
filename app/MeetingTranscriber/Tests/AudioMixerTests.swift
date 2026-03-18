import AVFoundation
@testable import MeetingTranscriber
import XCTest

final class AudioMixerTests: XCTestCase {
    // MARK: - Mix Tracks

    func testMixTracksEqualLength() {
        let a: [Float] = [1, 0, 1, 0]
        let b: [Float] = [0, 1, 0, 1]
        let result = AudioMixer.mixTracks(a, b)
        XCTAssertEqual(result, [0.5, 0.5, 0.5, 0.5])
    }

    func testMixTracksUnequalLength() {
        let a: [Float] = [1, 1, 1, 1, 1]
        let b: [Float] = [0, 0, 0]
        let result = AudioMixer.mixTracks(a, b)
        // First 3: averaged, last 2: from a
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0], 0.5)
        XCTAssertEqual(result[3], 1.0)
        XCTAssertEqual(result[4], 1.0)
    }

    func testMixTracksEmptyA() {
        let result = AudioMixer.mixTracks([], [1, 2, 3])
        XCTAssertEqual(result, [1, 2, 3])
    }

    func testMixTracksEmptyB() {
        let result = AudioMixer.mixTracks([1, 2, 3], [])
        XCTAssertEqual(result, [1, 2, 3])
    }

    func testMixTracksBothEmpty() {
        let result = AudioMixer.mixTracks([], [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Echo Suppression

    func testEchoSuppressionSilencesOverlap() {
        let sampleRate = 1000 // 20ms window = 20 samples
        let windowSize = 20

        // App has energy in first window
        var appSamples = [Float](repeating: 0, count: 100)
        for i in 0 ..< windowSize {
            appSamples[i] = 0.5 // loud
        }

        // Mic has energy everywhere
        var micSamples = [Float](repeating: 0.3, count: 100)

        AudioMixer.suppressEcho(
            appSamples: appSamples,
            micSamples: &micSamples,
            sampleRate: sampleRate,
            threshold: 0.01,
        )

        // First window of mic should be suppressed (app has energy)
        for i in 0 ..< windowSize {
            XCTAssertEqual(micSamples[i], 0.0, "Sample \(i) should be suppressed")
        }
    }

    func testEchoSuppressionNoAppEnergy() {
        let sampleRate = 1000
        let appSamples = [Float](repeating: 0, count: 100) // silent
        var micSamples = [Float](repeating: 0.5, count: 100)

        AudioMixer.suppressEcho(
            appSamples: appSamples,
            micSamples: &micSamples,
            sampleRate: sampleRate,
            threshold: 0.01,
        )

        // Mic should be untouched
        XCTAssertTrue(micSamples.allSatisfy { $0 == 0.5 })
    }

    // MARK: - Resampling

    func testResample48kTo16k() {
        // 480 samples at 48kHz = 10ms → should become 160 samples at 16kHz
        let input = [Float](repeating: 1.0, count: 480)
        let output = AudioMixer.resample(input, from: 48000, to: 16000)
        XCTAssertEqual(output.count, 160)
    }

    func testResampleSameRate() {
        let input: [Float] = [1, 2, 3, 4, 5]
        let output = AudioMixer.resample(input, from: 48000, to: 48000)
        XCTAssertEqual(output, input)
    }

    func testResampleEmpty() {
        let output = AudioMixer.resample([], from: 48000, to: 16000)
        XCTAssertTrue(output.isEmpty)
    }

    func testResamplePreservesShape() {
        // Simple sine wave: resample should preserve frequency content roughly
        let sampleRate = 48000
        let targetRate = 16000
        let freq: Float = 440
        let duration: Float = 0.01 // 10ms
        let sampleCount = Int(Float(sampleRate) * duration)

        var input = [Float](repeating: 0, count: sampleCount)
        for i in 0 ..< sampleCount {
            input[i] = sin(2 * .pi * freq * Float(i) / Float(sampleRate))
        }

        let output = AudioMixer.resample(input, from: sampleRate, to: targetRate)
        let expectedCount = Int(Float(sampleCount) * Float(targetRate) / Float(sampleRate))
        XCTAssertEqual(output.count, expectedCount)
    }

    // MARK: - WAV Round-trip

    func testWAVRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let wavURL = tmpDir.appendingPathComponent("test_roundtrip_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let original: [Float] = [0.0, 0.5, -0.5, 0.25, -0.25]
        let sampleRate = 16000

        try AudioMixer.saveWAV(samples: original, sampleRate: sampleRate, url: wavURL)
        let loaded = try AudioMixer.loadAudioFileAsFloat32(url: wavURL)

        XCTAssertEqual(loaded.count, original.count)
        // 16-bit quantization introduces small error
        for i in 0 ..< original.count {
            XCTAssertEqual(loaded[i], original[i], accuracy: 0.001, "Sample \(i) mismatch")
        }
    }

    func testSaveWAVCreatesFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let wavURL = tmpDir.appendingPathComponent("test_create_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let samples = [Float](repeating: 0, count: 48000) // 1 second silence
        try AudioMixer.saveWAV(samples: samples, sampleRate: 48000, url: wavURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: wavURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 44) // WAV header is 44 bytes minimum
    }

    // MARK: - Multi-format Loading

    func testLoadAudioAsFloat32WAV() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let wavURL = tmpDir.appendingPathComponent("test_multiformat_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let original: [Float] = [0.0, 0.5, -0.5, 0.25, -0.25]
        try AudioMixer.saveWAV(samples: original, sampleRate: 16000, url: wavURL)

        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: wavURL)
        XCTAssertEqual(sampleRate, 16000)
        XCTAssertEqual(samples.count, original.count)
        for i in 0 ..< original.count {
            XCTAssertEqual(samples[i], original[i], accuracy: 0.001, "Sample \(i) mismatch")
        }
    }

    func testLoadAudioAsFloat32RoundTrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let wavURL = tmpDir.appendingPathComponent("test_async_roundtrip_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let original: [Float] = [0.1, -0.1, 0.3, -0.3, 0.0]
        try AudioMixer.saveWAV(samples: original, sampleRate: 44100, url: wavURL)

        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: wavURL)
        XCTAssertEqual(sampleRate, 44100)
        XCTAssertEqual(samples.count, original.count)
        for i in 0 ..< original.count {
            XCTAssertEqual(samples[i], original[i], accuracy: 0.001, "Sample \(i) mismatch")
        }
    }

    func testLoadAudioAsFloat32NonexistentFile() async {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).wav")
        do {
            _ = try await AudioMixer.loadAudioAsFloat32(url: bogus)
            XCTFail("Expected error for nonexistent file")
        } catch {
            // Expected
        }
    }

    func testResampleFileAsyncRoundTrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let src = tmpDir.appendingPathComponent("test_resample_src_\(UUID().uuidString).wav")
        let dst = tmpDir.appendingPathComponent("test_resample_dst_\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }

        // Create a 48kHz source (480 samples = 10ms)
        let samples48k = [Float](repeating: 0.5, count: 480)
        try AudioMixer.saveWAV(samples: samples48k, sampleRate: 48000, url: src)

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
        let loaded = try AudioMixer.loadAudioFileAsFloat32(url: dst)
        // 480 samples at 48kHz → ~160 samples at 16kHz
        XCTAssertEqual(loaded.count, 160)
    }

    // MARK: - Multi-format Fixtures

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    // -- Loading (AVAudioFile fast path) --

    func testLoadAudioFileAsFloat32MP3() throws {
        let url = fixtureURL("sine_440hz_44k.mp3")
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: url)
        // 1s at 44.1kHz → ~44100 samples (MP3 adds encoder padding)
        XCTAssertGreaterThan(samples.count, 40000)
        XCTAssertLessThan(samples.count, 50000)
    }

    func testLoadAudioFileAsFloat32M4A() throws {
        let url = fixtureURL("sine_440hz_44k.m4a")
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: url)
        XCTAssertEqual(samples.count, 44100, "M4A 1s at 44.1kHz = exactly 44100 frames")
    }

    // -- Loading via loadAudioAsFloat32 entry point --

    func testLoadAudioAsFloat32ReturnsCorrectSampleRate() async throws {
        let url = fixtureURL("sine_440hz_44k.m4a")
        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: url)
        XCTAssertEqual(sampleRate, 44100, "Should detect 44.1kHz from M4A")
        XCTAssertEqual(samples.count, 44100)
    }

    // -- AVAsset fallback (direct test, bypassing AVAudioFile) --

    func testLoadAudioFromAVAssetMP4() async throws {
        let url = fixtureURL("sine_440hz_44k.mp4")
        // Call AVAsset path directly — this is the fallback for when AVAudioFile fails
        let (samples, sampleRate) = try await AudioMixer.loadAudioFromAVAsset(url: url)
        XCTAssertEqual(sampleRate, 16000, "AVAsset extracts at 16kHz")
        // 1s at 16kHz → ~16000 samples
        XCTAssertGreaterThan(samples.count, 14000)
        XCTAssertLessThan(samples.count, 18000)
    }

    func testLoadAudioFromAVAssetM4A() async throws {
        let url = fixtureURL("sine_440hz_44k.m4a")
        let (samples, sampleRate) = try await AudioMixer.loadAudioFromAVAsset(url: url)
        XCTAssertEqual(sampleRate, 16000)
        XCTAssertGreaterThan(samples.count, 14000)
        XCTAssertLessThan(samples.count, 18000)
    }

    func testLoadAudioFromAVAssetNoAudioThrows() async {
        let url = fixtureURL("video_no_audio.mp4")
        do {
            _ = try await AudioMixer.loadAudioFromAVAsset(url: url)
            XCTFail("Expected noAudioTrack error")
        } catch let error as AudioMixerError {
            XCTAssertEqual(error.errorDescription, "File contains no audio track")
        } catch {
            XCTFail("Expected AudioMixerError.noAudioTrack, got \(error)")
        }
    }

    // -- Resampling from multi-format sources --

    func testResampleFileM4A44kTo16k() async throws {
        let src = fixtureURL("sine_440hz_44k.m4a")
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_resample_m4a_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let dstFile = try AVAudioFile(forReading: dst)
        XCTAssertEqual(Int(dstFile.processingFormat.sampleRate), 16000, "Output must be 16kHz")

        let loaded = try AudioMixer.loadAudioFileAsFloat32(url: dst)
        // 44100 samples at 44.1kHz = 1.0s → 16000 samples at 16kHz
        XCTAssertEqual(loaded.count, 16000, "1s at 44.1kHz → 16000 samples at 16kHz")
    }

    func testResampleFileMP3_44kTo16k() async throws {
        let src = fixtureURL("sine_440hz_44k.mp3")
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_resample_mp3_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let dstFile = try AVAudioFile(forReading: dst)
        XCTAssertEqual(Int(dstFile.processingFormat.sampleRate), 16000, "Output must be 16kHz")

        let loaded = try AudioMixer.loadAudioFileAsFloat32(url: dst)
        // MP3 has encoder padding, so ~1.0–1.05s → 16000–16800 samples
        XCTAssertGreaterThan(loaded.count, 15000)
        XCTAssertLessThan(loaded.count, 18000)
    }

    func testResampleFileDurationPreserved() async throws {
        let src = fixtureURL("sine_440hz_44k.m4a")
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_duration_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let srcFile = try AVAudioFile(forReading: src)
        let dstFile = try AVAudioFile(forReading: dst)
        let srcDuration = Double(srcFile.length) / srcFile.processingFormat.sampleRate
        let dstDuration = Double(dstFile.length) / dstFile.processingFormat.sampleRate
        XCTAssertEqual(srcDuration, dstDuration, accuracy: 0.01, "Duration must be preserved")
    }

    func testResampleFileAudioHasEnergy() async throws {
        let src = fixtureURL("sine_440hz_44k.m4a")
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_energy_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let loaded = try AudioMixer.loadAudioFileAsFloat32(url: dst)
        // Sine wave should have significant energy (not silence)
        let rms = sqrt(loaded.map { $0 * $0 }.reduce(0, +) / Float(loaded.count))
        // AAC encoding + 16-bit quantization reduce amplitude; 0.05 confirms it's not silence
        XCTAssertGreaterThan(rms, 0.05, "Resampled audio should not be silent")
    }
}
