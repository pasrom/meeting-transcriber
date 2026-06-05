@testable import AudioTapLib
import CoreAudio
import XCTest

/// Pins the parts of the capture-time resampling contract that are testable
/// without a live CATap: the written-file format `AudioCaptureSession` relies
/// on, and the host-time extraction feeding the timeline anchor. The IOProc
/// write path itself is hardware-bound.
@available(macOS 14.2, *)
final class AppAudioCaptureResamplingTests: XCTestCase {
    func testOutputFormatIsSpeechRateMono() {
        // AudioCaptureSession reports this as the produced file's format —
        // buildRecording trusts it (and skips the rate cross-check on it).
        let capture = AppAudioCapture(pids: [], outputFileDescriptor: -1)
        XCTAssertEqual(capture.outputSampleRate, Int(speechSampleRate))
        XCTAssertEqual(capture.outputChannels, 1)
    }

    func testHostTicksUsesValidHostTime() {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = 12345
        stamp.mFlags = .hostTimeValid

        let ticks = withUnsafePointer(to: stamp) { AppAudioCapture.hostTicks(from: $0) }

        XCTAssertEqual(ticks, 12345, "a valid presentation timestamp must be used as-is")
    }

    func testHostTicksFallsBackToCallbackClockWhenInvalid() {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = 12345 // present but NOT marked valid

        let before = mach_absolute_time()
        let ticks = withUnsafePointer(to: stamp) { AppAudioCapture.hostTicks(from: $0) }

        XCTAssertGreaterThanOrEqual(
            ticks, before,
            "an unmarked host time must fall back to the callback clock, not be trusted",
        )
    }
}
