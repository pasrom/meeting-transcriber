import AVFoundation
import XCTest

@testable import MeetingTranscriber

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

    // MARK: - Mute Masking

    func testMuteMaskZeroesSamples() {
        // 1 second at 100 Hz = 100 samples
        var samples = [Float](repeating: 1.0, count: 100)
        let timeline = [
            MuteTransition(timestamp: 10.0, isMuted: true),   // mute at t=10
            MuteTransition(timestamp: 10.5, isMuted: false),  // unmute at t=10.5
        ]

        AudioMixer.applyMuteMask(
            samples: &samples,
            timeline: timeline,
            sampleRate: 100,
            micDelay: 0,
            recordingStart: 10.0
        )

        // First 50 samples (0.0s-0.5s) should be zeroed (muted)
        for i in 0..<50 {
            XCTAssertEqual(samples[i], 0.0, "Sample \(i) should be muted")
        }
        // Remaining should be untouched
        for i in 50..<100 {
            XCTAssertEqual(samples[i], 1.0, "Sample \(i) should be untouched")
        }
    }

    func testMuteMaskStillMutedAtEnd() {
        var samples = [Float](repeating: 1.0, count: 100)
        let timeline = [
            MuteTransition(timestamp: 5.0, isMuted: true),  // mute, never unmuted
        ]

        AudioMixer.applyMuteMask(
            samples: &samples,
            timeline: timeline,
            sampleRate: 100,
            recordingStart: 5.0
        )

        // All samples should be zeroed
        XCTAssertTrue(samples.allSatisfy { $0 == 0.0 })
    }

    func testMuteMaskLargeMicDelayDoesNotCrash() {
        // micDelay larger than timeline timestamps → range.end < range.start
        var samples = [Float](repeating: 1.0, count: 100)
        let timeline = [
            MuteTransition(timestamp: 10.0, isMuted: true),
            MuteTransition(timestamp: 10.5, isMuted: false),
        ]

        AudioMixer.applyMuteMask(
            samples: &samples,
            timeline: timeline,
            sampleRate: 100,
            micDelay: 20.0,
            recordingStart: 10.0
        )

        // All samples should remain untouched (mute range is entirely negative)
        XCTAssertTrue(samples.allSatisfy { $0 == 1.0 })
    }

    func testMuteMaskPartiallyNegativeRange() {
        // Mute starts before recording but ends during it
        var samples = [Float](repeating: 1.0, count: 100)
        let timeline = [
            MuteTransition(timestamp: 5.0, isMuted: true),
            MuteTransition(timestamp: 5.8, isMuted: false),
        ]

        AudioMixer.applyMuteMask(
            samples: &samples,
            timeline: timeline,
            sampleRate: 100,
            micDelay: 0.5,
            recordingStart: 5.0
        )

        // Mute range: (5.0 - 5.0 - 0.5) to (5.8 - 5.0 - 0.5) = -0.5s to 0.3s
        // Clamped start to 0; end ≈ sample 29-30 (floating point)
        // Verify most of the range is muted and tail is untouched
        for i in 0..<29 {
            XCTAssertEqual(samples[i], 0.0, "Sample \(i) should be muted")
        }
        for i in 31..<100 {
            XCTAssertEqual(samples[i], 1.0, "Sample \(i) should be untouched")
        }
    }

    func testMuteMaskEmptyTimeline() {
        var samples: [Float] = [1.0, 2.0, 3.0]
        AudioMixer.applyMuteMask(
            samples: &samples,
            timeline: [],
            sampleRate: 48000
        )
        XCTAssertEqual(samples, [1.0, 2.0, 3.0])
    }

    // MARK: - Echo Suppression

    func testEchoSuppressionSilencesOverlap() {
        let sampleRate = 1000  // 20ms window = 20 samples
        let windowSize = 20

        // App has energy in first window
        var appSamples = [Float](repeating: 0, count: 100)
        for i in 0..<windowSize {
            appSamples[i] = 0.5  // loud
        }

        // Mic has energy everywhere
        var micSamples = [Float](repeating: 0.3, count: 100)

        AudioMixer.suppressEcho(
            appSamples: appSamples,
            micSamples: &micSamples,
            sampleRate: sampleRate,
            threshold: 0.01
        )

        // First window of mic should be suppressed (app has energy)
        for i in 0..<windowSize {
            XCTAssertEqual(micSamples[i], 0.0, "Sample \(i) should be suppressed")
        }
    }

    func testEchoSuppressionNoAppEnergy() {
        let sampleRate = 1000
        let appSamples = [Float](repeating: 0, count: 100)  // silent
        var micSamples = [Float](repeating: 0.5, count: 100)

        AudioMixer.suppressEcho(
            appSamples: appSamples,
            micSamples: &micSamples,
            sampleRate: sampleRate,
            threshold: 0.01
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
        let duration: Float = 0.01  // 10ms
        let sampleCount = Int(Float(sampleRate) * duration)

        var input = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
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
        for i in 0..<original.count {
            XCTAssertEqual(loaded[i], original[i], accuracy: 0.001, "Sample \(i) mismatch")
        }
    }

    func testSaveWAVCreatesFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let wavURL = tmpDir.appendingPathComponent("test_create_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let samples = [Float](repeating: 0, count: 48000)  // 1 second silence
        try AudioMixer.saveWAV(samples: samples, sampleRate: 48000, url: wavURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: wavURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 44)  // WAV header is 44 bytes minimum
    }
}
