@testable import AudioTapLib
import AVFoundation
import XCTest

final class MicChannelMapTests: XCTestCase {
    /// 2ch layouts whose implicit downmix was measured to yield silence.
    /// `MidSide` and `XY` are what a stereo microphone pair reports.
    private static let silentStereoTags: [AudioChannelLayoutTag] = [
        kAudioChannelLayoutTag_StereoHeadphones,
        kAudioChannelLayoutTag_MatrixStereo,
        kAudioChannelLayoutTag_MidSide,
        kAudioChannelLayoutTag_XY,
        kAudioChannelLayoutTag_Binaural,
    ]

    private func taggedFormat(_ tag: AudioChannelLayoutTag) throws -> AVAudioFormat {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
        return AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
    }

    private func discreteFormat(channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try taggedFormat(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
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
        let discreteStereo = try discreteFormat(channels: 2)
        XCTAssertEqual(MicChannelMap.downmixMap(for: discreteStereo), [0])
    }

    func testDiscreteMicArrayNeedsExplicitMap() throws {
        // The built-in mic in voice-processing mode: 3ch discrete.
        let threeChannel = try discreteFormat(channels: 3)
        let fourChannel = try discreteFormat(channels: 4)
        XCTAssertEqual(MicChannelMap.downmixMap(for: threeChannel), [0])
        XCTAssertEqual(MicChannelMap.downmixMap(for: fourChannel), [0])
    }

    func testNamedStereoVariantsNeedExplicitMap() throws {
        // Every 2ch layout except the plain Stereo tag downmixes to silence,
        // including the two microphone-pair configurations (MidSide, XY).
        for tag in Self.silentStereoTags {
            let format = try taggedFormat(tag)
            XCTAssertEqual(
                MicChannelMap.downmixMap(for: format), [0],
                "layout tag \(String(format: "0x%06X", tag)) must not stay on the implicit path",
            )
        }
    }

    func testPlainStereoTagKeepsImplicitDownmix() throws {
        let stereo = try taggedFormat(kAudioChannelLayoutTag_Stereo)
        XCTAssertNil(MicChannelMap.downmixMap(for: stereo))
    }

    // MARK: - The behaviour the policy exists for

    /// Pins the actual AVAudioConverter defect: a discrete multichannel input
    /// downmixes to silence implicitly, and to real audio with the map. If a
    /// future macOS fixes the implicit path, the first assertion fails and this
    /// workaround can be revisited.
    func testImplicitDownmixIsSilentAndMapRestoresAudio() throws {
        for channels in [2, 3, 4] as [AVAudioChannelCount] {
            let inFormat = try discreteFormat(channels: channels)
            try assertImplicitSilentAndMapAudible(inFormat, label: "discrete \(channels)ch")
        }
        for tag in Self.silentStereoTags {
            let inFormat = try taggedFormat(tag)
            try assertImplicitSilentAndMapAudible(inFormat, label: String(format: "tag 0x%06X", tag))
        }
    }

    /// The plain Stereo tag is the one layout the allowlist keeps on the
    /// implicit path, so its fold has to stay correct for that to be safe.
    func testPlainStereoStillFoldsCorrectlyWithoutAMap() throws {
        let stereo = try taggedFormat(kAudioChannelLayoutTag_Stereo)
        let peak = try convertPeak(from: stereo, channelMap: nil)
        XCTAssertEqual(peak, 0.5, accuracy: 0.01)
    }

    private func assertImplicitSilentAndMapAudible(
        _ inFormat: AVAudioFormat, label: String, file: StaticString = #filePath, line: UInt = #line,
    ) throws {
        let implicitPeak = try convertPeak(from: inFormat, channelMap: nil)
        XCTAssertEqual(
            implicitPeak, 0, accuracy: 0.0001,
            "\(label): implicit downmix is expected to yield silence", file: file, line: line,
        )
        let mappedPeak = try convertPeak(from: inFormat, channelMap: MicChannelMap.downmixMap(for: inFormat))
        XCTAssertEqual(
            mappedPeak, 0.5, accuracy: 0.01,
            "\(label): explicit channel map must preserve the signal", file: file, line: line,
        )
    }

    // swiftlint:disable:next discouraged_optional_collection legacy_objc_type
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
        let feed = FeedOnce(buffer: inBuf)
        converter.convert(to: outBuf, error: &error) { _, status in
            feed.next(status)
        }
        if let error { throw error }

        let samples = try XCTUnwrap(outBuf.floatChannelData)[0]
        return (0 ..< Int(outBuf.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
    }
}
