@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// Tests the engine-free silence writer behind the mic gap-fill. The gap
/// *arithmetic* is covered by `TimelineAnchorTests`; this verifies the silence
/// actually lands in the file, zeroed and at the right length. The handler
/// itself is deliberately never instantiated — its deinit touches
/// `AVAudioEngine.inputNode`, which is fatal on input-less CI hosts.
final class MicCaptureHandlerTimelineTests: XCTestCase {
    /// Mirror MicCaptureHandler.startEngine's output settings. A function
    /// rather than a `static let` — `[String: Any]` is not Sendable, so a
    /// shared stored value trips Swift 6 strict concurrency.
    private func wavSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: speechSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mic_timeline_\(UUID().uuidString).wav")
    }

    func testWriteSilenceAppendsZeroedFrames() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Scope the writer so it finalizes the WAV header before read-back —
        // AVAudioFile only completes the header on deallocation.
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: wavSettings())
            MicCaptureHandler.writeSilence(frames: 14400, to: file)
            XCTAssertEqual(file.length, 14400, "the gap must land in the file at full length")
        }

        // Read back and prove the frames are actual silence.
        let reader = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: reader.processingFormat, frameCapacity: 14400,
        ))
        try reader.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 14400)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "gap frames must be zeroed, not garbage")
    }

    func testWriteSilenceZeroFramesWritesNothing() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forWriting: url, settings: wavSettings())
        MicCaptureHandler.writeSilence(frames: 0, to: file)

        XCTAssertEqual(file.length, 0, "no gap, no write")
    }
}
