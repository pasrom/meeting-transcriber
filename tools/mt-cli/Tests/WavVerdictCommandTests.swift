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

    /// A read that returns fewer frames than asked for is continued until the
    /// last frame.
    func testAShortFirstReadIsContinuedToTheLastFrame() throws {
        var sizes = [4, 3, 100]
        var requests: [Int] = []

        let read = try WavVerdictCommand.readAllFrames(total: 10) { maxFrames in
            requests.append(maxFrames)
            return min(sizes.isEmpty ? 0 : sizes.removeFirst(), maxFrames)
        }

        XCTAssertEqual(read, 10)
        XCTAssertEqual(requests, [10, 6, 3])
    }

    func testAReadOfZeroFramesEndsTheLoop() throws {
        var sizes = [4, 0, 6]
        var requests = 0

        let read = try WavVerdictCommand.readAllFrames(total: 10) { maxFrames in
            requests += 1
            return min(sizes.removeFirst(), maxFrames)
        }

        XCTAssertEqual(read, 4)
        XCTAssertEqual(requests, 2)
    }

    /// A read at the end of a file throws; after frames were read that is the
    /// end of a file shorter than its length, not a failure.
    func testAnEndOfFileErrorAfterSomeFramesEndsTheLoop() throws {
        var reads = 0

        let read = try WavVerdictCommand.readAllFrames(total: 10) { maxFrames in
            reads += 1
            if reads == 1 { return min(4, maxFrames) }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(eofErr))
        }

        XCTAssertEqual(read, 4)
    }

    /// A mono 32-bit float file longer than 65,536 frames: one read sized to the
    /// whole file returns short for it (measured on macOS 27.2.1).
    func testLoadSamplesReadsEveryFrameOfALongFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wav-verdict-long-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeToneWav(url: url, freq: 440, seconds: 10, sampleRate: 16000, amplitude: 0.3)

        let (samples, _) = try WavVerdictCommand.loadSamples(path: url.path)

        XCTAssertEqual(samples.count, 160_000)
    }
}
