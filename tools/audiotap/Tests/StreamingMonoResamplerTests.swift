@testable import AudioTapLib
import XCTest

final class StreamingMonoResamplerTests: XCTestCase {
    // MARK: - Basic conversion

    func testEmptyInputReturnsEmpty() throws {
        let resampler = try XCTUnwrap(StreamingMonoResampler(targetRate: 16000))
        XCTAssertEqual(resampler.process([], inputRate: 48000, inputChannels: 2), [])
    }

    func testDownmixesAndResamplesStereo() throws {
        let resampler = try XCTUnwrap(StreamingMonoResampler(targetRate: 16000))
        // 1 s of 48 kHz interleaved stereo, L=0.4 R=0.6 → mono average 0.5.
        var stereo = [Float]()
        stereo.reserveCapacity(48000 * 2)
        for _ in 0 ..< 48000 {
            stereo.append(0.4)
            stereo.append(0.6)
        }

        let out = resampler.process(stereo, inputRate: 48000, inputChannels: 2)

        XCTAssertEqual(out.count, 16000, accuracy: 300, "1 s of 48 kHz stereo → ~16000 mono samples")
        let mid = out[out.count / 2]
        XCTAssertEqual(mid, 0.5, accuracy: 0.05, "stereo must downmix to the channel average")
    }

    // MARK: - Rate change mid-stream (issue #379 follow-up: "tape-stop" drift)

    /// The core of the fix. A mid-recording output-device change renegotiates
    /// the capture rate (e.g. 48 kHz → 24 kHz). The converter MUST be rebuilt
    /// for the new rate; a stale 48 kHz converter fed a 24 kHz span produces
    /// only ~8000 samples (2× too fast / an octave low — the slowed, low-pitched
    /// speaker-naming clips jhavez reported). Each span must map 1 s → 1 s.
    func testRebuildsConverterWhenInputRateChanges() throws {
        let resampler = try XCTUnwrap(StreamingMonoResampler(targetRate: 16000))

        let first = resampler.process([Float](repeating: 0.5, count: 48000), inputRate: 48000, inputChannels: 1)
        XCTAssertEqual(first.count, 16000, accuracy: 300, "1 s @48 kHz → 1 s @16 kHz")

        // Device renegotiated to 24 kHz mid-recording.
        let second = resampler.process([Float](repeating: -0.5, count: 24000), inputRate: 24000, inputChannels: 1)
        XCTAssertEqual(
            second.count, 16000, accuracy: 300,
            "1 s @24 kHz must still map to 1 s @16 kHz after the converter is rebuilt",
        )
        XCTAssertLessThan(second.max() ?? 1, 0, "the 24 kHz span content (negative fill) must be preserved")
    }

    /// A channel-count change across a device swap (2ch → 1ch) must also rebuild
    /// the converter rather than misread the interleaving.
    func testRebuildsConverterWhenChannelCountChanges() throws {
        let resampler = try XCTUnwrap(StreamingMonoResampler(targetRate: 16000))

        let stereo = [Float](repeating: 0.5, count: 48000 * 2) // 1 s stereo
        let firstStereo = resampler.process(stereo, inputRate: 48000, inputChannels: 2)
        XCTAssertEqual(firstStereo.count, 16000, accuracy: 300)

        let mono = [Float](repeating: 0.5, count: 48000) // 1 s mono, same rate
        let thenMono = resampler.process(mono, inputRate: 48000, inputChannels: 1)
        XCTAssertEqual(
            thenMono.count, 16000, accuracy: 300,
            "1 s of mono must still map to 1 s after a channel-count change",
        )
    }
}
