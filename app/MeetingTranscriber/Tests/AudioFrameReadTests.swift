import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// The whole-file loader reads until the file's last frame, not just once.
/// One read sized to the whole file returns short for a mono 32-bit float
/// file longer than 65,536 frames (measured on macOS 27.2.1), which the
/// real-file test below catches; the loop itself is pinned with a fake reader.
final class AudioFrameReadTests: XCTestCase {
    /// A reader that hands back fewer frames than asked for, as a decoder may.
    private final class ShortReader {
        private(set) var requests: [Int] = []
        let sizes: [Int]

        init(sizes: [Int]) {
            self.sizes = sizes
        }

        func read(_ maxFrames: Int) -> Int {
            let size = requests.count < sizes.count ? sizes[requests.count] : 0
            requests.append(maxFrames)
            return min(size, maxFrames)
        }
    }

    func testAShortFirstReadIsContinuedToTheLastFrame() throws {
        let reader = ShortReader(sizes: [4, 3, 100])

        let read = try AudioMixer.readAllFrames(total: 10, readChunk: reader.read)

        XCTAssertEqual(read, 10)
        XCTAssertEqual(reader.requests, [10, 6, 3], "each read asks for what is still missing")
    }

    func testAReadOfZeroFramesEndsTheLoop() throws {
        let reader = ShortReader(sizes: [4, 0, 6])

        let read = try AudioMixer.readAllFrames(total: 10, readChunk: reader.read)

        XCTAssertEqual(read, 4, "a file that ends early ends the loop instead of spinning")
        XCTAssertEqual(reader.requests.count, 2)
    }

    func testAnEmptyFileReadsNothing() throws {
        let reader = ShortReader(sizes: [4])

        XCTAssertEqual(try AudioMixer.readAllFrames(total: 0, readChunk: reader.read), 0)
        XCTAssertTrue(reader.requests.isEmpty)
    }

    private let endOfFile = NSError(domain: NSOSStatusErrorDomain, code: Int(eofErr))

    /// What a read at the end of a file does (it throws): reached when a file
    /// decodes to fewer frames than its length says, where one read used to
    /// return the shorter buffer.
    func testAnEndOfFileErrorAfterSomeFramesEndsTheLoop() throws {
        var reads = 0

        let read = try AudioMixer.readAllFrames(total: 10) { maxFrames in
            reads += 1
            if reads == 1 { return min(4, maxFrames) }
            throw endOfFile
        }

        XCTAssertEqual(read, 4)
    }

    func testAnEndOfFileErrorBeforeAnyFrameIsThrown() {
        XCTAssertThrowsError(try AudioMixer.readAllFrames(total: 10) { _ in throw endOfFile })
    }

    func testAnotherErrorAfterSomeFramesIsThrown() {
        var reads = 0
        XCTAssertThrowsError(try AudioMixer.readAllFrames(total: 10) { maxFrames in
            reads += 1
            if reads == 1 { return min(4, maxFrames) }
            throw AudioMixerError.noFloatData
        })
    }

    /// The loader on a real file longer than one read chunk returns every
    /// sample in order, and averages a stereo file to mono as before.
    func testAFileLongerThanOneChunkLoadsEverySample() throws {
        let dir = try makeTempDirectory(prefix: "frame_read")
        let frames = 150_000
        for channels in [1, 2] {
            let url = dir.appendingPathComponent("ramp_\(channels).caf")
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                channels: AVAudioChannelCount(channels), interleaved: false,
            ))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0 ..< frames {
                data[0][i] = Float(i % 1000) / 1000
                if channels == 2 { data[1][i] = -Float(i % 500) / 1000 }
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }

            let samples = try AudioMixer.loadAudioFileAsFloat32(url: url)

            guard samples.count == frames else {
                XCTFail("read \(samples.count) of \(frames) frames, \(channels) channel(s)")
                continue
            }
            for i in [0, 65535, 65536, 131_072, frames - 1] {
                let expected = channels == 1
                    ? data[0][i]
                    : (data[0][i] + data[1][i]) * (1 / Float(2))
                XCTAssertEqual(samples[i], expected, "sample \(i), \(channels) channel(s)")
            }
        }
    }

    // MARK: - Span reads

    /// A file whose reads hand back at most `cap` frames, as a decoder may.
    /// Short reads on any system, so the span helpers are pinned whether or not
    /// this macOS cuts a real read short.
    /// `@unchecked Sendable` restates what `AVAudioFile` declares; each test
    /// uses its file from one thread.
    private final class CappedReadFile: AVAudioFile, @unchecked Sendable {
        var cap: AVAudioFrameCount = 1000
        private(set) var reads = 0

        override func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
            reads += 1
            try super.read(into: buffer, frameCount: min(frames, cap))
        }
    }

    /// Ten thousand frames whose every value is its own, as a 16-bit file.
    private func writeRamp() throws -> (url: URL, ramp: [Float]) {
        let url = try makeTempDirectory(prefix: "span_read").appendingPathComponent("ramp.wav")
        let ramp = (0 ..< 10000).map { Float($0) / 10000 * 0.9 }
        try AudioMixer.saveWAV(samples: ramp, sampleRate: 16000, url: url)
        return (url, ramp)
    }

    private func assertSamples(_ got: [Float], equal expected: ArraySlice<Float>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, expected.count, file: file, line: line)
        let worst = zip(got, expected).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThanOrEqual(worst, 2.0 / 32768, "read from the wrong position", file: file, line: line)
    }

    func testReadFramesContinuesShortReadsFromTheFilePosition() throws {
        let (url, ramp) = try writeRamp()
        let file = try CappedReadFile(forReading: url)
        file.framePosition = 1234
        var got: [Float] = []

        let read = try AudioMixer.readFrames(from: file, count: 5000) { channels, frames in
            got.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
        }

        XCTAssertEqual(read, 5000)
        assertSamples(got, equal: ramp[1234 ..< 6234])
        XCTAssertEqual(file.reads, 5, "five reads capped at 1,000 frames")
    }

    func testReadFirstChannelContinuesShortReadsAndStopsAtTheEnd() throws {
        let (url, ramp) = try writeRamp()
        let file = try CappedReadFile(forReading: url)
        file.cap = 300
        file.framePosition = 2500

        try assertSamples(AudioMixer.readFirstChannel(of: file, count: 4000), equal: ramp[2500 ..< 6500])
        // Asks past the end: what is left, not an error.
        try assertSamples(AudioMixer.readFirstChannel(of: file, count: 5000), equal: ramp[6500...])
        XCTAssertEqual(try AudioMixer.readFirstChannel(of: file, count: 10), [])
    }

    /// The call-site tests for span reads (the speaker snippet, the echo
    /// quarantine, echo classification and echo cancellation) fail without
    /// the chunked read only where one `read(into:)` of a mono float file
    /// really comes back short, as it does on macOS 27.2.1. This says when
    /// that stopped holding: it skips, rather than leaving those tests green
    /// for no reason. The capped-read tests above hold either way.
    func testSingleReadsOfAMonoFloatFileStillReturnShort() throws {
        let url = try makeTempDirectory(prefix: "single_read").appendingPathComponent("float.wav")
        try writeMonoFloat32WAV((0 ..< 300_000).map { Float($0 % 1000) / 1000 }, to: url)

        func singleRead(from start: Int, count: Int) throws -> Int {
            let file = try AVAudioFile(forReading: url)
            file.framePosition = AVAudioFramePosition(start)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count),
            ))
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            return Int(buffer.frameLength)
        }
        let fromStart = try singleRead(from: 0, count: 100_000)
        let afterSeek = try singleRead(from: 50000, count: 16384)

        try XCTSkipIf(
            fromStart == 100_000 || afterSeek == 16384,
            "One read of a mono float file came back whole on this macOS (\(fromStart) of 100,000 frames "
                + "from the start, \(afterSeek) of 16,384 after a seek), so the call-site tests for short "
                + "span reads cannot fail here.",
        )
    }
}
