@testable import AudioTapLib
import XCTest

final class LiveAudioBufferTests: XCTestCase {
    func test_init_preservesAllFields() {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let buf = LiveAudioBuffer(
            samples: samples,
            channelCount: 2,
            sampleRate: 48000,
            hostTime: 1_234_567,
        )
        XCTAssertEqual(buf.samples, samples)
        XCTAssertEqual(buf.channelCount, 2)
        XCTAssertEqual(buf.sampleRate, 48000)
        XCTAssertEqual(buf.hostTime, 1_234_567)
    }

    func test_init_acceptsEmptySamples() {
        let buf = LiveAudioBuffer(
            samples: [], channelCount: 1, sampleRate: 16000, hostTime: 0,
        )
        XCTAssertTrue(buf.samples.isEmpty)
        XCTAssertEqual(buf.channelCount, 1)
        XCTAssertEqual(buf.sampleRate, 16000)
        XCTAssertEqual(buf.hostTime, 0)
    }

    func test_isSendable_canBeCapturedInSendableClosure() {
        // Compile-time check: a Sendable struct can be captured by a @Sendable
        // closure without warnings. If LiveAudioBuffer loses Sendable conformance
        // this stops compiling.
        let buf = LiveAudioBuffer(
            samples: [1, 2, 3], channelCount: 1, sampleRate: 16000, hostTime: 42,
        )
        let sendableClosure: @Sendable () -> Int = { buf.samples.count }
        XCTAssertEqual(sendableClosure(), 3)
    }
}
