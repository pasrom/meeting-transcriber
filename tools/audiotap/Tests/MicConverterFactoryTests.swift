@testable import AudioTapLib
import AVFoundation
import XCTest

/// Covers the seam the silent-mic bug actually lived at: `MicChannelMap` can be
/// perfectly correct and the mic track still records silence if the converter
/// the capture path builds never gets the map applied. These tests drive the
/// factory the handler uses, so dropping the `channelMap` assignment fails them
/// even though every `MicChannelMapTests` case still passes.
final class MicConverterFactoryTests: XCTestCase {
    private let fileRate: Double = 16000

    private func taggedFormat(_ tag: AudioChannelLayoutTag) throws -> AVAudioFormat {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
        return AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
    }

    /// The device state a WeChat / FaceTime / Teams call puts the built-in mic
    /// into: 48 kHz, 3 channels, discrete layout.
    private func voiceProcessingMicFormat() throws -> AVAudioFormat {
        try taggedFormat(kAudioChannelLayoutTag_DiscreteInOrder | 3)
    }

    func testNoConverterWhenTapAlreadyMatchesTheFile() throws {
        let matching = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: fileRate, channels: 1))
        XCTAssertNil(MicConverterFactory.make(tapFormat: matching, fileSampleRate: fileRate))
    }

    func testMicArrayConverterCarriesAnExplicitChannelMap() throws {
        let tapFormat = try voiceProcessingMicFormat()
        let setup = try XCTUnwrap(MicConverterFactory.make(tapFormat: tapFormat, fileSampleRate: fileRate))
        XCTAssertEqual(setup.converter.channelMap, [0])
        XCTAssertEqual(setup.selectedChannel, 0)
    }

    func testPlainStereoConverterKeepsTheImplicitFold() throws {
        let stereo = try taggedFormat(kAudioChannelLayoutTag_Stereo)
        let setup = try XCTUnwrap(MicConverterFactory.make(tapFormat: stereo, fileSampleRate: fileRate))
        XCTAssertNil(setup.selectedChannel)
    }

    /// The end the user notices: audio in, audio out. Without the explicit map
    /// this converter writes digital zeros for the whole call.
    func testMicArrayConverterProducesAudioRatherThanSilence() throws {
        let tapFormat = try voiceProcessingMicFormat()
        let setup = try XCTUnwrap(MicConverterFactory.make(tapFormat: tapFormat, fileSampleRate: fileRate))

        let frames: AVAudioFrameCount = 4800
        let inBuf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frames))
        inBuf.frameLength = frames
        for channel in 0 ..< Int(tapFormat.channelCount) {
            let samples = try XCTUnwrap(inBuf.floatChannelData)[channel]
            for frame in 0 ..< Int(frames) {
                samples[frame] = 0.5 * sinf(2 * .pi * 440 * Float(frame) / 48000)
            }
        }

        let outBuf = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: setup.converter.outputFormat, frameCapacity: 1600),
        )
        var error: NSError?
        let feed = FeedOnce(buffer: inBuf)
        setup.converter.convert(to: outBuf, error: &error) { _, status in
            feed.next(status)
        }
        XCTAssertNil(error)

        let samples = try XCTUnwrap(outBuf.floatChannelData)[0]
        let peak = (0 ..< Int(outBuf.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
        XCTAssertEqual(peak, 0.5, accuracy: 0.01, "the capture path must not write digital silence")
    }
}
