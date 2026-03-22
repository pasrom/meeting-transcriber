import Accelerate
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

    // MARK: - Frequency Preservation (Mickey Mouse Prevention)

    func testResample48kTo16kPreservesFrequency() {
        let inputRate = 48000
        let outputRate = 16000
        let input = Self.generateSine(frequency: 440, sampleRate: inputRate, duration: 1.0)

        let output = AudioMixer.resample(input, from: inputRate, to: outputRate)
        let peak = Self.peakFrequency(samples: output, sampleRate: outputRate)

        XCTAssertEqual(peak, 440, accuracy: 440 * 0.05, "48k→16k must preserve 440Hz (got \(peak)Hz)")
    }

    func testResample44kTo16kPreservesFrequency() {
        let inputRate = 44100
        let outputRate = 16000
        let input = Self.generateSine(frequency: 440, sampleRate: inputRate, duration: 1.0)

        let output = AudioMixer.resample(input, from: inputRate, to: outputRate)
        let peak = Self.peakFrequency(samples: output, sampleRate: outputRate)

        XCTAssertEqual(peak, 440, accuracy: 440 * 0.05, "44.1k→16k must preserve 440Hz (got \(peak)Hz)")
    }

    func testResample96kTo16kPreservesFrequency() {
        let inputRate = 96000
        let outputRate = 16000
        let input = Self.generateSine(frequency: 440, sampleRate: inputRate, duration: 1.0)

        let output = AudioMixer.resample(input, from: inputRate, to: outputRate)
        let peak = Self.peakFrequency(samples: output, sampleRate: outputRate)

        XCTAssertEqual(peak, 440, accuracy: 440 * 0.05, "96k→16k must preserve 440Hz (got \(peak)Hz)")
    }

    func testResample16kTo16kPreservesFrequency() {
        let rate = 16000
        let input = Self.generateSine(frequency: 440, sampleRate: rate, duration: 1.0)

        let output = AudioMixer.resample(input, from: rate, to: rate)
        let peak = Self.peakFrequency(samples: output, sampleRate: rate)

        XCTAssertEqual(peak, 440, accuracy: 440 * 0.05, "Same-rate passthrough must preserve 440Hz (got \(peak)Hz)")
    }

    func testResampleWithWrongSourceRateShiftsFrequency() {
        // 440Hz generated at 48kHz, but tell resampler it's 24kHz → frequency doubles to ~880Hz
        let input = Self.generateSine(frequency: 440, sampleRate: 48000, duration: 1.0)

        let output = AudioMixer.resample(input, from: 24000, to: 16000)
        let peak = Self.peakFrequency(samples: output, sampleRate: 16000)

        // With wrong source rate, frequency should be shifted far from 440Hz
        let deviation = abs(peak - 440) / 440
        XCTAssertGreaterThan(deviation, 0.3, "Wrong source rate must shift frequency (got \(peak)Hz, expected ~880Hz)")
    }

    func testResampleFilePreservesFrequency() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let src = tmpDir.appendingPathComponent("test_freq_src_\(UUID().uuidString).wav")
        let dst = tmpDir.appendingPathComponent("test_freq_dst_\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }

        // 440Hz sine at 48kHz, save to WAV, resample file to 16kHz
        let input = Self.generateSine(frequency: 440, sampleRate: 48000, duration: 1.0)
        try AudioMixer.saveWAV(samples: input, sampleRate: 48000, url: src)

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let loaded = try AudioMixer.loadAudioFileAsFloat32(url: dst)
        let peak = Self.peakFrequency(samples: loaded, sampleRate: 16000)

        XCTAssertEqual(peak, 440, accuracy: 440 * 0.05, "File round-trip must preserve 440Hz (got \(peak)Hz)")
    }

    func testSaveWAVHeaderSampleRateCorrect() throws {
        let tmpDir = FileManager.default.temporaryDirectory

        for rate in [48000, 16000, 44100] {
            let url = tmpDir.appendingPathComponent("test_header_\(rate)_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            let samples = [Float](repeating: 0, count: rate) // 1s silence
            try AudioMixer.saveWAV(samples: samples, sampleRate: rate, url: url)

            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(
                Int(file.processingFormat.sampleRate), rate,
                "WAV header must report \(rate)Hz",
            )
        }
    }

    func testResampleFileFromM4APreservesFrequency() async throws {
        let src = fixtureURL("sine_440hz_44k.m4a")
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_freq_m4a_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let loaded = try AudioMixer.loadAudioFileAsFloat32(url: dst)
        let peak = Self.peakFrequency(samples: loaded, sampleRate: 16000)

        XCTAssertEqual(peak, 440, accuracy: 440 * 0.05, "M4A→16k must preserve 440Hz (got \(peak)Hz)")
    }
}

// MARK: - FFT Helpers

private extension AudioMixerTests {
    /// Detect dominant frequency via FFT (vDSP).
    static func peakFrequency(samples: [Float], sampleRate: Int) -> Double {
        let n = samples.count
        let log2n = vDSP_Length(floor(log2(Double(n))))
        let fftSize = Int(1 << log2n)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return 0
        }
        defer { vDSP_destroy_fftsetup(fft) }

        var realPart = [Float](samples.prefix(fftSize))
        var imagPart = [Float](repeating: 0, count: fftSize)

        let peakBin: Int = realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                guard let realPtr = realBuf.baseAddress,
                      let imagPtr = imagBuf.baseAddress else { return 0 }
                var splitComplex = DSPSplitComplex(
                    realp: realPtr,
                    imagp: imagPtr,
                )
                vDSP_fft_zip(fft, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

                var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                // Skip bin 0 (DC offset)
                var maxVal: Float = 0
                var maxIdx: vDSP_Length = 0
                vDSP_maxvi(Array(magnitudes.dropFirst()), 1, &maxVal, &maxIdx, vDSP_Length(magnitudes.count - 1))
                return Int(maxIdx) + 1
            }
        }

        let freqResolution = Double(sampleRate) / Double(fftSize)
        return Double(peakBin) * freqResolution
    }

    /// Generate a mono sine wave at a given frequency.
    static func generateSine(frequency: Double, sampleRate: Int, duration: Double) -> [Float] {
        let sampleCount = Int(Double(sampleRate) * duration)
        return (0 ..< sampleCount).map { i in
            sin(2 * .pi * Float(frequency) * Float(i) / Float(sampleRate))
        }
    }
}
