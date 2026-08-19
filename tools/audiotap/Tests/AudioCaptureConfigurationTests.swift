@testable import AudioTapLib
import Foundation
import XCTest

/// What a capture configuration is when the caller says the minimum.
final class AudioCaptureConfigurationTests: XCTestCase {
    /// The optional extras, and above all the e2e fault: it is the one field
    /// the init does not take, so it arrives by Swift's implicit nil rather
    /// than by an assignment anyone wrote. A shipped binary that reached the
    /// session with it set would self-trigger a device-change restart on every
    /// recording.
    func testTheOptionalExtrasStartUnset() {
        let config = AudioCaptureConfiguration(
            pids: [], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2,
        )

        XCTAssertNil(config.micDeviceUID, "nil means the system default input")
        XCTAssertFalse(config.debugLogging)
        XCTAssertNil(config.appLiveSink)
        XCTAssertNil(config.micLiveSink)
        XCTAssertNil(config.micDebugFault, "every shipped binary leaves the e2e fault unset")
    }

    /// Not a test that a struct stores what it is given: the init is written by
    /// hand, nine assignments long, and the two track URLs are both `URL?`, so
    /// swapping them compiles and would send each track to the other's file.
    /// Distinct values on both, so a swap fails in either direction.
    func testTheTwoTrackURLsDoNotCrossOnTheWayIn() {
        let app = URL(fileURLWithPath: "/tmp/stem_app_raw.tmp")
        let mic = URL(fileURLWithPath: "/tmp/stem_mic.wav")

        let config = AudioCaptureConfiguration(
            pids: [7], appOutputURL: app, micOutputURL: mic, sampleRate: 48000, channels: 2,
        )

        XCTAssertEqual(config.appOutputURL, app)
        XCTAssertEqual(config.micOutputURL, mic)
        XCTAssertEqual(config.pids, [7])
    }
}
