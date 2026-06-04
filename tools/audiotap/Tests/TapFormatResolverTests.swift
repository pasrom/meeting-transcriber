import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// Guards the issue #379 root-cause invariant: the mic tap format must match
/// the hardware node's CHANNEL count. A regression to a hardcoded 1-channel
/// tap (the original bug) makes `testTapFormatPreservesChannelCount` fail.
final class TapFormatResolverTests: XCTestCase {
    private func hw(_ rate: Double, _ channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
    }

    func testMonoHardwareYieldsMonoTap() throws {
        let tap = try TapFormatResolver.tapFormat(forHardware: hw(24000, 1))
        XCTAssertEqual(tap?.channelCount, 1)
        XCTAssertEqual(tap?.sampleRate, 24000)
    }

    func testTapFormatPreservesChannelCount() throws {
        // The root-cause fix: a 2-channel device must produce a 2-channel tap,
        // not a hardcoded 1-channel one (which raised on the real device).
        // A revert to forcing 1 channel fails this assertion.
        XCTAssertEqual(try TapFormatResolver.tapFormat(forHardware: hw(44100, 2))?.channelCount, 2)
    }

    func testPreservesSampleRate() throws {
        XCTAssertEqual(try TapFormatResolver.tapFormat(forHardware: hw(44100, 2))?.sampleRate, 44100)
    }

    func testZeroSampleRateRejected() throws {
        // A transient dead device (0 Hz) must yield nil so the caller can
        // retry instead of force-unwrapping or letting installTap raise.
        let zeroRate = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false,
        ))
        XCTAssertNil(TapFormatResolver.tapFormat(forHardware: zeroRate))
    }
}
