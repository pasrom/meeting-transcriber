@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// Pins that `MicCaptureHandler` drives its engine through `MicEngineSessionProviding`
/// and touches no `AVAudioEngine` itself.
///
/// This matters beyond tidiness: every call that can wedge (issue #588) now lives
/// behind this seam, so a test can substitute a session that never reaches audio
/// hardware. That is not optional, it is the only way these paths are testable at
/// all: the CI runner has no input device, and reading `AVAudioEngine.inputNode`
/// there raises an uncatchable NSException.
final class MicEngineSessionSeamTests: XCTestCase {
    /// Records what the handler asked of its session, in order.
    private final class FakeSession: MicEngineSessionProviding {
        enum Call: Equatable {
            case hardwareFormat(deviceUID: String?)
            case installTap(sampleRate: Double)
            case start
            case teardown
        }

        private(set) var calls: [Call] = []
        let notificationObject: AnyObject = NSObject()
        /// Local bookkeeping, not a protocol requirement: nothing in production
        /// asks a session whether its tap is attached.
        private(set) var tapInstalled = false
        // 44.1 kHz stereo, the format a built-in mic reports after a Bluetooth
        // device goes away (measured in the incident). Force-unwrapped because a
        // standard format at a valid rate cannot fail, and a fake that cannot be
        // built is a broken test either way.
        // swiftlint:disable:next force_unwrapping
        var format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        var hardwareFormatError: Error?

        func hardwareFormat(deviceUID: String?) throws -> AVAudioFormat {
            calls.append(.hardwareFormat(deviceUID: deviceUID))
            if let hardwareFormatError { throw hardwareFormatError }
            return format
        }

        /// The handler's real tap block, so a test can drive audio through the
        /// production write path after the fact.
        var tapBlock: AVAudioNodeTapBlock?

        func installTap(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
            calls.append(.installTap(sampleRate: format.sampleRate))
            tapBlock = block
            tapInstalled = true
        }

        func start() {
            calls.append(.start)
        }

        func teardown() {
            calls.append(.teardown)
            tapInstalled = false
        }
    }

    private func makeHandler(_ session: FakeSession) -> (MicCaptureHandler, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seam-\(UUID().uuidString).wav")
        let handler = MicCaptureHandler(outputURL: url) { session }
        return (handler, url)
    }

    func testStartDrivesTheSessionInOrder() throws {
        let session = FakeSession()
        let (handler, url) = makeHandler(session)
        defer { try? FileManager.default.removeItem(at: url) }

        try handler.start()

        XCTAssertEqual(session.calls, [
            .hardwareFormat(deviceUID: nil),
            .installTap(sampleRate: 44100),
            .start,
        ])
        handler.stop()
    }

    func testSelectedDeviceIsPassedToTheSession() throws {
        let session = FakeSession()
        let (handler, url) = makeHandler(session)
        defer { try? FileManager.default.removeItem(at: url) }

        try handler.start(deviceUID: "SomeDeviceUID")

        XCTAssertEqual(session.calls.first, .hardwareFormat(deviceUID: "SomeDeviceUID"))
        handler.stop()
    }

    func testStopTearsTheSessionDown() throws {
        let session = FakeSession()
        let (handler, url) = makeHandler(session)
        defer { try? FileManager.default.removeItem(at: url) }

        try handler.start()
        handler.stop()

        XCTAssertEqual(session.calls.last, .teardown)
    }

    func testAFailingHardwareFormatIsPropagatedAndNothingElseRuns() throws {
        // The wedge point's error path: whatever comes back from the engine must
        // reach the caller, and the tap must not be installed on a half-built
        // session.
        let session = FakeSession()
        session.hardwareFormatError = MicCaptureError.noInputDevice
        let (handler, url) = makeHandler(session)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try handler.start())
        XCTAssertEqual(session.calls, [.hardwareFormat(deviceUID: nil)])
        XCTAssertFalse(session.tapInstalled)
    }

    // MARK: - Converter ownership (issue #589)

    func testATapBlockKeepsWritingAfterAnotherAttemptBuildsADifferentFormat() throws {
        // A restart attempt configures the converter for ITS format before the
        // arbiter has agreed to adopt it. While that runs, the still-installed
        // tap block of the previous session keeps receiving buffers. If the
        // converter is shared, those buffers are fed through a converter built
        // for a format they do not have, and the audio is silently dropped.
        let running = FakeSession()
        running.format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let attempt = FakeSession()
        attempt.format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var sessions = [running, attempt]
        let handler = MicCaptureHandler(outputURL: url) { sessions.removeFirst() }

        try handler.start()
        let block = try XCTUnwrap(running.tapBlock)
        let sizeAfterStart = try Data(contentsOf: url).count

        // A second attempt configures itself for a different format.
        _ = try handler.startEngine(deviceUID: nil, on: attempt)

        // The first session's block is still installed and still delivering.
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: running.format, frameCapacity: 4096))
        buffer.frameLength = 4096
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0 ..< 4096 {
            samples[frame] = Float(sin(Double(frame) * 0.05)) * 0.5
        }
        block(buffer, AVAudioTime(hostTime: mach_absolute_time()))
        handler.stop()

        XCTAssertGreaterThan(
            try Data(contentsOf: url).count,
            sizeAfterStart,
            "audio delivered to a session's own tap block must reach the file",
        )
    }
}
