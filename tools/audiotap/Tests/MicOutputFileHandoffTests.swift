@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The render thread writes to `outputFile` while the main queue drops it.
///
/// The assertion here is thin on purpose. A load racing a store-and-release has
/// no reliable observable behaviour: it does nothing for years, then frees a file
/// mid-write on someone's machine. What this test does is create the unordered
/// pair, so ThreadSanitizer has something to report. Run it under
/// `--sanitize=thread` and it flags an unguarded property and is silent on a
/// guarded one, which is what makes it a check rather than decoration.
///
/// Deliberately free of cross-thread signalling before the stop. An expectation
/// fulfilled from the delivering thread, a `queue.sync`, or a semaphore signalled
/// from the loop would each establish a happens-before edge between the two
/// accesses and blind the sanitizer to exactly the pair under test. The only
/// coordination is wall-clock sleep, which orders nothing.
final class MicOutputFileHandoffTests: XCTestCase {
    private final class Fake: MicEngineSessionProviding {
        let notificationObject: AnyObject = NSObject()
        // swiftlint:disable:next force_unwrapping
        private let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        var tapBlock: AVAudioNodeTapBlock?

        func hardwareFormat(deviceUID _: String?) -> AVAudioFormat {
            fmt
        }

        func installTap(format _: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
            tapBlock = block
        }

        func start() {}
        func teardown() {}
    }

    func testTheRenderThreadCanDeliverWhileTheMainQueueDropsTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let fake = Fake()
        let handler = MicCaptureHandler(outputURL: url) { fake }
        try handler.start()
        // `nonisolated(unsafe)`: a tap block is a bare function value, so the
        // `@preconcurrency` import does not reach it and the dispatch closure
        // below cannot capture it otherwise. Deliberately not a lock or a queue:
        // any real ordering primitive would establish the happens-before edge
        // this test exists to leave out.
        nonisolated(unsafe) let block = try XCTUnwrap(fake.tapBlock, "start() must install the production tap block")

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0 ..< 256 {
            samples[frame] = Float(sin(Double(frame) * 0.05)) * 0.5
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0 ..< 20000 {
                block(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
            }
            finished.signal()
        }
        // Wall clock only: let the loop get going, then stop underneath it.
        usleep(50000)
        handler.stop()
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success, "the delivering loop must finish")

        XCTAssertNil(handler.outputFile, "stop must leave no file behind for a later buffer to find")
    }
}
