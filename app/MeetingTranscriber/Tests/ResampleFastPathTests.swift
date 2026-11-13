import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// `AudioMixer.resampleFile` copies a source instead of converting it only when
/// the source already has the format its output promises: 16 kHz mono linear
/// PCM WAV. Everything else, including a source that merely shares the rate, is
/// converted.
final class ResampleFastPathTests: XCTestCase {
    /// A stereo source already at the target rate must still come out mono.
    /// Transcription and diarization downmix whatever they open, but the readers
    /// that cut spans out of the 16 kHz file (speaker-naming snippets, the echo
    /// checks) take channel 0, so a copied stereo file hands them the left
    /// channel alone and a speaker recorded on the right one plays back silent.
    /// The channels differ so a copy, a left-only read and a proper fold all
    /// produce different numbers.
    func testResampleFileFoldsStereoSourceAtTargetRateToMono() async throws {
        let src = makeTempFile(suffix: ".wav")
        let dst = makeTempFile(suffix: ".wav")
        let frames = 1600
        try writePCM(levels: [0.6, 0.2], float32: false, frames: frames, sampleRate: 16000, url: src)

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let output = try AVAudioFile(forReading: dst)
        XCTAssertEqual(output.fileFormat.channelCount, 1, "the 16 kHz file must be mono")
        XCTAssertEqual(Int(output.fileFormat.sampleRate), 16000)
        XCTAssertEqual(Int(output.length), frames, "a fold keeps the frame count")

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        try output.read(into: buffer)
        let firstChannel = try Array(UnsafeBufferPointer(start: XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        XCTAssertEqual(firstChannel.count, frames)
        let worst = try XCTUnwrap(firstChannel.max { abs($0 - 0.4) < abs($1 - 0.4) })
        XCTAssertEqual(worst, 0.4, accuracy: 0.001, "channel 0 must hold the average of both channels")
    }

    /// The fast path itself stays: a file that already is what the destination
    /// promises (16 kHz mono linear PCM WAV) is copied byte for byte rather than
    /// decoded and re-encoded. The source is 32-bit float, which the conversion
    /// never writes, so equal bytes can only come from a copy.
    func testResampleFileCopiesMonoPCMWAVAtTargetRateVerbatim() async throws {
        let src = makeTempFile(suffix: ".wav")
        let dst = makeTempFile(suffix: ".wav")
        try writePCM(levels: [0.3], float32: true, frames: 1600, sampleRate: 16000, url: src)

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: src))
    }

    /// The 16 kHz file may hold meeting audio, so it is private to the user
    /// however it was produced. A copy would otherwise carry the source's mode,
    /// while every converted file is written 0600.
    func testResampleFileCopyIsPrivateToTheUser() async throws {
        let src = makeTempFile(suffix: ".wav")
        let dst = makeTempFile(suffix: ".wav")
        try writePCM(levels: [0.3], float32: true, frames: 1600, sampleRate: 16000, url: src)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: src.path)

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dst.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, FileManager.ownerOnlyPermissions)
    }

    /// The container is read from the file, not from its name. Mono linear PCM
    /// at the target rate in an AIFF container that merely carries a `.wav`
    /// name is not a WAV, so it is converted and the output is one.
    func testResampleFileConvertsAnAIFFThatIsNamedWAV() async throws {
        let aiff = makeTempFile(suffix: ".aiff")
        let src = makeTempFile(suffix: ".wav")
        let dst = makeTempFile(suffix: ".wav")
        try writePCM(levels: [0.3], float32: true, frames: 1600, sampleRate: 16000, url: aiff)
        try? FileManager.default.removeItem(at: src)
        try FileManager.default.moveItem(at: aiff, to: src)
        XCTAssertEqual(try Data(contentsOf: src).prefix(4), Data("FORM".utf8), "precondition: the source is an AIFF")

        try await AudioMixer.resampleFile(from: src, to: dst, targetRate: 16000)

        let output = try Data(contentsOf: dst)
        XCTAssertEqual(output.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(output.dropFirst(8).prefix(4), Data("WAVE".utf8))
    }

    /// Linear PCM with one constant level per channel, in the container the
    /// file name asks for.
    private func writePCM(levels: [Float], float32: Bool, frames: Int, sampleRate: Int, url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: levels.count,
            AVLinearPCMBitDepthKey: float32 ? 32 : 16,
            AVLinearPCMIsFloatKey: float32,
            AVLinearPCMIsBigEndianKey: url.pathExtension == "aiff",
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for (index, level) in levels.enumerated() {
            for i in 0 ..< frames {
                channels[index][i] = level
            }
        }
        try file.write(from: buffer)
    }
}
