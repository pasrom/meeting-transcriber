import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The notice for a microphone whose first start did not return within its
/// deadline (issue #778), through the controller that posts it. What the
/// text may claim is in `MicStallNoticeCopyTests`.
@MainActor
final class MicFirstStartTimeoutNoticeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A microphone whose first start never came back (issue #778) is
    /// reported through the same give-up, at once and as lost, but with its
    /// own text: the restart message says a restart failed, and nothing was
    /// restarted.
    func testAMicrophoneWhoseFirstStartTimedOutIsToldItsOwnGiveUp() {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make(for: self)
        recorder.appLevelDBFS = -20
        recorder.micLevelDBFS = -120
        recorder.micCaptureGaveUp = true
        recorder.micCaptureStartTimedOut = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertEqual(notifier.calls.count, 1, "told at once, without waiting out the silence window")
        XCTAssertEqual(notifier.calls.first?.title, "Capture Channel Lost")
        XCTAssertEqual(
            notifier.calls.first?.body,
            ChannelHealthController.captureGaveUpMessage(for: .mic, startTimedOut: true),
        )
        XCTAssertNotEqual(
            notifier.calls.first?.body,
            ChannelHealthController.captureGaveUpMessage(for: .mic),
        )
    }

    /// The flag describes the microphone only: an app track that gives up in
    /// the same recording keeps its own message.
    func testAnAppGiveUpBesideATimedOutMicrophoneKeepsItsOwnMessage() {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make(for: self)
        recorder.micCaptureGaveUp = true
        recorder.micCaptureStartTimedOut = true
        recorder.appCaptureGaveUp = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertEqual(
            Set(notifier.calls.map(\.body)),
            [
                ChannelHealthController.captureGaveUpMessage(for: .mic, startTimedOut: true),
                ChannelHealthController.captureGaveUpMessage(for: .app),
            ],
        )
    }
}
