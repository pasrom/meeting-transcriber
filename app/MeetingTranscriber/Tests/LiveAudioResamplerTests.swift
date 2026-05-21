import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Sanity tests for `LiveAudioResampler`. Avoids assertions on the actual
/// resampled audio (AVAudioConverter's interpolation can drift sample
/// counts by ±1 across macOS versions); checks structural invariants
/// instead — channel count, sample rate, non-emptiness, pass-through.
final class LiveAudioResamplerTests: XCTestCase {
    func testPassThroughWhenAlreadyTargetFormat() {
        let resampler = LiveAudioResampler()
        let samples: [Float] = (0 ..< 1600).map { Float($0) / 1600.0 }
        let input = LiveAudioBuffer(
            samples: samples,
            channelCount: 1,
            sampleRate: 16000,
            hostTime: 1,
        )
        let output = resampler.resample(input)
        XCTAssertNotNil(output)
        guard let output else { return }
        XCTAssertEqual(output.channelCount, 1)
        XCTAssertEqual(output.sampleRate, 16000)
        XCTAssertEqual(output.samples, input.samples) // identity
        XCTAssertEqual(output.hostTime, input.hostTime)
    }

    func testEmptyInputReturnsNil() {
        let resampler = LiveAudioResampler()
        let empty = LiveAudioBuffer(
            samples: [],
            channelCount: 1,
            sampleRate: 16000,
            hostTime: 0,
        )
        XCTAssertNil(resampler.resample(empty))
    }

    func testStereo48kInputIsResampledToMono16k() {
        let resampler = LiveAudioResampler()
        // Build 4800 interleaved stereo Float32 samples (= 100 ms at 48 kHz).
        // Left channel sine, right zero — channel reduction shouldn't drop
        // the signal, just produce output that's non-empty.
        var samples: [Float] = []
        samples.reserveCapacity(4800 * 2)
        for i in 0 ..< 4800 {
            let s = Float(sin(2.0 * .pi * 440.0 * Double(i) / 48000.0))
            samples.append(s)
            samples.append(0)
        }
        let input = LiveAudioBuffer(
            samples: samples,
            channelCount: 2,
            sampleRate: 48000,
            hostTime: 1,
        )
        let output = resampler.resample(input)
        XCTAssertNotNil(output)
        guard let output else { return }
        XCTAssertEqual(output.channelCount, 1)
        XCTAssertEqual(output.sampleRate, 16000)
        XCTAssertFalse(output.samples.isEmpty)
        // 100 ms × 16 kHz = 1600 frames in steady state, but the
        // converter's first call drops a chunk to warm interpolation
        // state. Empirically lands at ~1360 on Apple Silicon. We don't
        // care about the exact count here — just that resampling
        // produced a plausibly-sized buffer (between 50 ms and 150 ms
        // worth of mono output).
        XCTAssertGreaterThan(output.samples.count, 800)
        XCTAssertLessThan(output.samples.count, 2400)
    }

    func testFormatChangeMidSessionRebuildsConverter() {
        let resampler = LiveAudioResampler()
        // First buffer: 48 kHz stereo
        let buf48 = LiveAudioBuffer(
            samples: [Float](repeating: 0.1, count: 9600), // 4800 frames stereo
            channelCount: 2,
            sampleRate: 48000,
            hostTime: 1,
        )
        XCTAssertNotNil(resampler.resample(buf48))
        // Second buffer: 44.1 kHz mono — converter must rebuild
        let buf44 = LiveAudioBuffer(
            samples: [Float](repeating: 0.1, count: 4410), // 100 ms
            channelCount: 1,
            sampleRate: 44100,
            hostTime: 2,
        )
        let output = resampler.resample(buf44)
        XCTAssertNotNil(output)
        if let output {
            XCTAssertEqual(output.channelCount, 1)
            XCTAssertEqual(output.sampleRate, 16000)
        }
    }
}
