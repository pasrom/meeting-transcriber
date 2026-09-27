import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// What the microphone's stall and give-up notices may claim. The text is
/// worded from what the capture layer reported, so each state gets a test of
/// its own; that the controller passes the reported stall through is in
/// `ChannelFaultIntegrationTests`.
final class MicStallNoticeCopyTests: XCTestCase {
    /// A microphone that never delivered did not stop: an engine that comes
    /// up silent from its first second is the shape the watchdog exists for.
    func testAStallOfAMicrophoneThatNeverDeliveredDoesNotSayItStopped() {
        let body = ChannelHealthController.captureStalledMessage(for: MicStallDetails(everDelivered: false))
        XCTAssertFalse(body.contains("stopped delivering"), body)
        XCTAssertTrue(body.contains("has not delivered any audio"), body)
    }

    func testAStallOfAMicrophoneThatDeliveredSaysItStopped() {
        let body = ChannelHealthController.captureStalledMessage(for: MicStallDetails(everDelivered: true))
        XCTAssertTrue(body.contains("stopped delivering audio"), body)
    }

    /// Past the last allowed revival a change of input is ignored, so that
    /// stall must not tell the user to make one.
    func testTheStallAfterTheLastRevivalDoesNotOfferASwitch() {
        let body = ChannelHealthController.captureStalledMessage(for: MicStallDetails(mayRevive: false))
        XCTAssertFalse(body.contains("makes it try again"), body)
        XCTAssertTrue(body.contains("stays released until the recording ends"), body)
    }

    func testAStallThatMayStillBeRevivedOffersTheSwitchAndItsLimit() {
        let body = ChannelHealthController.captureStalledMessage(for: MicStallDetails(mayRevive: true))
        XCTAssertTrue(body.contains("makes it try again"), body)
        XCTAssertTrue(body.contains("After \(MicCaptureProgressPolicy.maxRevivalsWithoutAudio) tries"), body)
    }

    /// The watchdog's own rebuilds can wedge or fail too, with no device
    /// change anywhere, so the microphone's give-up must not claim one. The
    /// app-audio channel is only restarted by a device change.
    func testTheMicrophoneGiveUpDoesNotBlameADeviceChange() {
        XCTAssertFalse(ChannelHealthController.captureGaveUpMessage(for: .mic).contains("device change"))
        XCTAssertTrue(ChannelHealthController.captureGaveUpMessage(for: .app).contains("device change"))
    }
}
