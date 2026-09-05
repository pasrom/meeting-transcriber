@testable import AudioTapLib
import CoreAudio
import XCTest

/// The CoreAudio rate queries and the ladder that picks between them.
///
/// These need a real device to answer, which a test machine may or may not
/// have, so what is pinned here is the half that is machine-independent: what
/// each query does when the object it is asked about does not exist, and that
/// the ladder falls back rather than publishing something implausible. That is
/// the path a session takes when its device disappears mid-restart, and it was
/// the one part of the rate resolution with no coverage at all.
@available(macOS 14.2, *)
final class AppAudioCaptureRateQueriesTests: XCTestCase {
    private let unknown = AudioObjectID(kAudioObjectUnknown)

    func testEveryQueryReportsNoRateForAnObjectThatDoesNotExist() {
        // Zero is the ladder's "could not be queried" signal, so each of these
        // returning it is what lets the rung below be tried. A query that
        // returned a plausible-looking number here would be adopted.
        XCTAssertEqual(AppAudioCapture.queryNominalSampleRate(deviceID: unknown), 0)
        XCTAssertEqual(AppAudioCapture.queryStreamSampleRate(deviceID: unknown), 0)
        XCTAssertEqual(AppAudioCapture.queryTapSampleRate(tapID: unknown), 0)
        XCTAssertEqual(AppAudioCapture.queryActualSampleRate(deviceID: unknown), 0)
    }

    func testTheLadderFallsBackToTheRequestedRateWhenNothingAnswers() {
        // With no tap, no nominal rate and no stream format, the requested rate
        // is all there is. Publishing 0 instead would make the resampler build a
        // converter against nothing, and the restart coordinator treats a
        // rate-zero start as a failure wearing a success's clothes.
        XCTAssertEqual(
            AppAudioCapture.resolveActualSampleRate(
                deviceID: unknown, tapID: unknown, requestedRate: 48000,
            ),
            48000,
        )
        XCTAssertEqual(
            AppAudioCapture.resolveActualSampleRate(
                deviceID: unknown, tapID: unknown, requestedRate: 16000,
            ),
            16000,
        )
    }
}
