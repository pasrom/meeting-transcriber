@testable import AudioTapLib
import Foundation
import XCTest

/// `start()` refuses a session with nothing to record. This is the one arm of
/// the new optional-app-track shape that is reachable without a CATap or an
/// input device: the guard runs before either track's hardware is touched.
final class AudioCaptureSessionTracksTests: XCTestCase {
    func testStartRefusesASessionWithNeitherTrack() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let session = AudioCaptureSession(AudioCaptureConfiguration(pids: [], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2))

        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertEqual(error as? AudioCaptureSessionError, .noTracksRequested)
        }
    }

    func testRefusalHappensBeforeAnyFileIsCreated() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        // A PID list without an output URL used to be impossible; assert the
        // guard keys on the URL, not on the PIDs, so a stray PID list cannot
        // talk the session into opening a tap it has nowhere to write.
        let session = AudioCaptureSession(AudioCaptureConfiguration(pids: [1, 2, 3], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2))

        XCTAssertThrowsError(try session.start())
    }
}
