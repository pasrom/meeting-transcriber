import AVFoundation
@testable import mt_cli
import XCTest

/// Covers the thin AVAudioFile I/O layer of the `wav-verdict` command. Writes a
/// real WAV via AVAudioFile (no `sox` dependency) and reads it back through
/// `loadSamples`, then confirms the pure verdict agrees.
final class WavVerdictCommandTests: XCTestCase {
    private func writeToneWav(url: URL, freq: Double, seconds: Double, sampleRate: Double, amplitude: Float) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false,
        ) else {
            throw XCTSkip("could not build audio format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw XCTSkip("could not allocate buffer")
        }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else {
            throw XCTSkip("no float channel data")
        }
        for i in 0 ..< Int(frames) {
            channel[i] = amplitude * sin(2 * Float.pi * Float(freq) * Float(i) / Float(sampleRate))
        }
        try file.write(from: buffer)
    }

    func testLoadSamplesReadsBackWrittenTone() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wav-verdict-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeToneWav(url: url, freq: 440, seconds: 1, sampleRate: 16000, amplitude: 0.3)

        let (samples, sampleRate) = try WavVerdictCommand.loadSamples(path: url.path)
        XCTAssertEqual(sampleRate, 16000, accuracy: 1)
        // AVAudioFile WAV round-trips can drop a few hundred frames and the
        // amount is macOS-version-sensitive, so assert a lower bound, not the
        // exact 16000 — the verdict, not the sample count, is the contract.
        XCTAssertGreaterThan(samples.count, 15000)

        let verdict = WavVerdict.analyze(samples: samples, sampleRate: sampleRate)
        XCTAssertFalse(verdict.isSilent, "a 0.3-amplitude tone must read back non-silent")
        XCTAssertEqual(verdict.activeWindowRatio, 1.0, accuracy: 0.001)
    }

    func testLoadSamplesOnSilentWavIsSilent() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wav-verdict-silent-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeToneWav(url: url, freq: 440, seconds: 1, sampleRate: 16000, amplitude: 0)

        let (samples, sampleRate) = try WavVerdictCommand.loadSamples(path: url.path)
        let verdict = WavVerdict.analyze(samples: samples, sampleRate: sampleRate)
        XCTAssertTrue(verdict.isSilent)
    }

    func testLoadSamplesMissingFileThrows() {
        XCTAssertThrowsError(
            try WavVerdictCommand.loadSamples(path: "/tmp/definitely-missing-\(UUID().uuidString).wav"),
        )
    }
}
