@testable import AudioTapLib
import AVFoundation
import XCTest

final class MicChannelMapTests: XCTestCase {
    private func discreteFormat(channels: AVAudioChannelCount) throws -> AVAudioFormat {
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
        return AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
    }

    // MARK: - Policy

    func testMonoNeedsNoMap() throws {
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        XCTAssertNil(MicChannelMap.downmixMap(for: mono))
    }

    func testStandardStereoKeepsImplicitDownmix() throws {
        // Standard stereo folds L+R correctly — don't throw away a channel.
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        XCTAssertNil(MicChannelMap.downmixMap(for: stereo))
    }

    func testDiscreteStereoNeedsExplicitMap() throws {
        XCTAssertEqual(MicChannelMap.downmixMap(for: try discreteFormat(channels: 2)), [0])
    }

    func testDiscreteMicArrayNeedsExplicitMap() throws {
        // The built-in mic in voice-processing mode: 3ch discrete.
        XCTAssertEqual(MicChannelMap.downmixMap(for: try discreteFormat(channels: 3)), [0])
        XCTAssertEqual(MicChannelMap.downmixMap(for: try discreteFormat(channels: 4)), [0])
    }

    // MARK: - The behaviour the policy exists for

    /// Pins the actual AVAudioConverter defect: a discrete multichannel input
    /// downmixes to silence implicitly, and to real audio with the map. If a
    /// future macOS fixes the implicit path, the first assertion fails and this
    /// workaround can be revisited.
    func testImplicitDownmixIsSilentAndMapRestoresAudio() throws {
        for channels in [2, 3, 4] as [AVAudioChannelCount] {
            let inFormat = try discreteFormat(channels: channels)
            XCTAssertEqual(
                try convertPeak(from: inFormat, channelMap: nil), 0, accuracy: 0.0001,
                "discrete \(channels)ch implicit downmix is expected to yield silence",
            )
            XCTAssertEqual(
                try convertPeak(from: inFormat, channelMap: MicChannelMap.downmixMap(for: inFormat)), 0.5,
                accuracy: 0.01, "explicit channel map must preserve the signal (\(channels)ch)",
            )
        }
    }

    /// Feeds one buffer of a 0.5-amplitude sine on every channel through the
    /// same conversion MicCaptureHandler performs; returns the output peak.
    private func convertPeak(from inFormat: AVAudioFormat, channelMap: [NSNumber]?) throws -> Float {
        let outFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: inFormat, to: outFormat))
        if let channelMap { converter.channelMap = channelMap }

        let frames: AVAudioFrameCount = 4800
        let inBuf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames))
        inBuf.frameLength = frames
        for channel in 0 ..< Int(inFormat.channelCount) {
            let samples = try XCTUnwrap(inBuf.floatChannelData)[channel]
            for frame in 0 ..< Int(frames) {
                samples[frame] = 0.5 * sinf(2 * .pi * 440 * Float(frame) / 48000)
            }
        }

        let outBuf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1600))
        var error: NSError?
        var fed = false
        converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { throw error }

        let samples = try XCTUnwrap(outBuf.floatChannelData)[0]
        return (0 ..< Int(outBuf.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
    }
}
