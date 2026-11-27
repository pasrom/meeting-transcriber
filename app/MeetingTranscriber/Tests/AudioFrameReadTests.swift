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
}
