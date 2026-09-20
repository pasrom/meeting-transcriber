import AVFoundation
@testable import MeetingTranscriber
import XCTest

final class AudioMixerStreamingTests: XCTestCase {
    func testSinglePCMBufferCapacityRejectsLongStereoRecording() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false,
        ))

        XCTAssertTrue(AudioMixer.canAllocateSinglePCMBuffer(frameCount: 536_870_908, format: format))
        for frameCount in 536_870_909 ... 536_870_911 {
            XCTAssertFalse(AudioMixer.canAllocateSinglePCMBuffer(frameCount: AVAudioFramePosition(frameCount), format: format))
        }
        XCTAssertFalse(AudioMixer.canAllocateSinglePCMBuffer(frameCount: 768_159_744, format: format))
        XCTAssertTrue(AudioMixer.canAllocateSinglePCMBuffer(
            frameCount: 48000,
            format: format,
        ))
    }

    func testStreamResampleFileWritesEntireStereoSource() async throws {
        let sourceURL = makeTempFile(suffix: ".wav")
        let destinationURL = makeTempFile(suffix: ".wav")
        let sourceRate = 48000
        let targetRate = 16000
        let duration = 2.0
        try writeStereoSine(
            to: sourceURL,
            settings: writerSettings(rate: Double(sourceRate)),
            rate: Double(sourceRate),
            duration: duration,
            amplitudes: (left: 0.8, right: 0.4),
        )
        let sourceFormat = try AVAudioFile(forReading: sourceURL).processingFormat

        try await AudioMixer.streamResampleFile(
            from: sourceURL,
            to: destinationURL,
            targetRate: targetRate,
            sourceChannelCount: sourceFormat.channelCount,
        )

        let output = try AudioMixer.loadAudioFileAsFloat32(url: destinationURL)
        XCTAssertEqual(output.count, Int(duration * Double(targetRate)))
        XCTAssertEqual(AudioMixer.rmsDecibels(samples: output.prefix(targetRate / 10)), -7.45, accuracy: 1.0)
        XCTAssertEqual(AudioMixer.rmsDecibels(samples: output.suffix(targetRate / 10)), -7.45, accuracy: 1.0)
    }

    func testStreamResampleFilePreservesBigEndianAudio() async throws {
        let sourceURL = makeTempFile(suffix: ".aiff")
        let destinationURL = makeTempFile(suffix: ".wav")
        var settings = try writerSettings(rate: 48000)
        settings[AVLinearPCMIsBigEndianKey] = true
        try writeStereoSine(
            to: sourceURL,
            settings: settings,
            rate: 48000,
            duration: 2,
            amplitudes: (left: 0.5, right: 0.5),
        )
        let sourceFormat = try AVAudioFile(forReading: sourceURL).processingFormat

        try await AudioMixer.streamResampleFile(
            from: sourceURL,
            to: destinationURL,
            targetRate: 16000,
            sourceChannelCount: sourceFormat.channelCount,
        )

        let output = try AudioMixer.loadAudioFileAsFloat32(url: destinationURL)
        XCTAssertEqual(AudioMixer.rmsDecibels(samples: output), -9.0, accuracy: 1.0)
        XCTAssertLessThan(output.map(abs).max() ?? 0, 0.95)
    }

    func testStreamResampleFileDecodesDiscreteChannelLayout() async throws {
        let sourceURL = makeTempFile(suffix: ".caf")
        let destinationURL = makeTempFile(suffix: ".wav")
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | 2
        var settings = try writerSettings(rate: 48000)
        settings[AVChannelLayoutKey] = Data(
            bytes: &layout,
            count: MemoryLayout<AudioChannelLayout>.size,
        )
        try writeStereoSine(
            to: sourceURL,
            settings: settings,
            rate: 48000,
            duration: 2,
            amplitudes: (left: 0.5, right: 0.5),
        )
        let sourceFormat = try AVAudioFile(forReading: sourceURL).processingFormat

        try await AudioMixer.streamResampleFile(
            from: sourceURL,
            to: destinationURL,
            targetRate: 16000,
            sourceChannelCount: sourceFormat.channelCount,
        )

        let output = try AudioMixer.loadAudioFileAsFloat32(url: destinationURL)
        XCTAssertGreaterThan(AudioMixer.rmsDecibels(samples: output), -40)
    }

    func testStreamResampleFileDoesNotFabricateLargeSilentTail() async throws {
        let sourceURL = fixtureURL("two_speakers_de.opus")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sourceURL.path), "Fixture not found")
        let destinationURL = makeTempFile(suffix: ".wav")
        let sourceFile = try AVAudioFile(forReading: sourceURL)

        do {
            try await AudioMixer.streamResampleFile(
                from: sourceURL,
                to: destinationURL,
                targetRate: 16000,
                sourceChannelCount: sourceFile.processingFormat.channelCount,
            )
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
            XCTAssertTrue(error.localizedDescription.contains("decoded"))
            return
        }

        let outputFile = try AVAudioFile(forReading: destinationURL)
        let sourceSeconds = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate
        let outputSeconds = Double(outputFile.length) / outputFile.processingFormat.sampleRate
        XCTAssertEqual(outputSeconds, sourceSeconds, accuracy: 0.02)
    }

    private func writerSettings(rate: Double) throws -> [String: Any] {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 2,
            interleaved: false,
        ))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        return settings
    }

    private func writeStereoSine(
        to url: URL,
        settings: [String: Any],
        rate: Double,
        duration: Double,
        amplitudes: (left: Float, right: Float),
    ) throws {
        let frameCount = Int(rate * duration)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount),
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for (channel, amplitude) in [amplitudes.left, amplitudes.right].enumerated() {
            let samples = (0 ..< frameCount).map { index in
                amplitude * sin(2 * .pi * 440 * Float(index) / Float(rate))
            }
            channelData[channel].update(from: samples, count: frameCount)
        }
        try file.write(from: buffer)
    }
}
