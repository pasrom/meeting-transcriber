@testable import AudioTapLib
import Foundation
import XCTest

/// `start()` refuses a session with nothing to record. This is the one arm of
/// the new optional-app-track shape that is reachable without a CATap or an
/// input device: the guard runs before either track's hardware is touched.
final class AudioCaptureSessionTracksTests: XCTestCase {
    func testAnUnopenedChannelReportsNoSignalAges() throws {
        // "Never opened" and "opened, then went quiet" are different faults and
        // must not collapse into one value. The levels cannot keep them apart,
        // both being -120; the ages can, by being absent rather than large.
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let session = AudioCaptureSession(AudioCaptureConfiguration(
            pids: [], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2,
        ))

        XCTAssertEqual(session.micSignalAges, .unknown)
        XCTAssertEqual(session.appSignalAges, .unknown)
    }

    func testStartRefusesASessionWithNeitherTrack() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let session = AudioCaptureSession(AudioCaptureConfiguration(pids: [], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2))

        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertEqual(error as? AudioCaptureSessionError, .noTracksRequested)
        }
    }

    /// What the session reads back out of its configuration, pinned where it is
    /// reachable without hardware.
    ///
    /// The session used to hold these as ten separate properties and now holds
    /// the configuration whole, so every read inside it was rewritten by hand.
    /// Three of those reads land in `stop()`'s result, and each has a same-typed
    /// neighbour it could have been swapped with: the two track URLs are both
    /// `URL?`, the rate and the channel count are both `Int`. Distinct values
    /// throughout, so a swap in either direction fails.
    ///
    /// A `stop()` with no `start()` touches nothing: both captures are nil, so
    /// the reported rate and channel count fall back to the configured ones and
    /// the app track is reported straight from the configuration.
    func testStopReportsTheTrackAndFormatItWasConfiguredWith() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let app = URL(fileURLWithPath: "/tmp/stem_app16k_raw.tmp")
        let mic = URL(fileURLWithPath: "/tmp/stem_mic.wav")
        let session = AudioCaptureSession(AudioCaptureConfiguration(
            pids: [], appOutputURL: app, micOutputURL: mic, sampleRate: 44100, channels: 5,
        ))

        let result = session.stop()

        XCTAssertEqual(result.appAudioFileURL, app, "the app track, not the mic file")
        XCTAssertEqual(result.actualSampleRate, 44100, "the configured rate, not the channel count")
        XCTAssertEqual(result.actualChannels, 5)
        XCTAssertNil(result.micAudioFileURL, "no mic capture ran, so there is no mic track to report")
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
