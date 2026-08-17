@testable import MeetingTranscriber
import XCTest

final class MicrophoneRecordingAvailabilityTests: XCTestCase {
    func testReadyWhenNothingIsInTheWay() {
        let state = MicrophoneRecordingAvailability.resolve(isRecording: false, noMic: false)

        XCTAssertEqual(state, .ready)
        XCTAssertTrue(state.allowsStart)
        XCTAssertNil(state.disabledReason)
    }

    func testNoMicSettingBlocksTheStart() {
        // Starting anyway would record nothing, since the entry point is the
        // microphone; overriding the setting silently would record the one
        // thing it exists to keep off tape.
        let state = MicrophoneRecordingAvailability.resolve(isRecording: false, noMic: true)

        XCTAssertEqual(state, .blockedByNoMicSetting)
        XCTAssertFalse(state.allowsStart)
    }

    func testARunningRecordingBlocksTheStart() {
        XCTAssertEqual(
            MicrophoneRecordingAvailability.resolve(isRecording: true, noMic: false),
            .recordingActive,
        )
    }

    func testARunningRecordingOutranksTheSetting() {
        // Both true: the honest reason is the one the user can act on right now.
        XCTAssertEqual(
            MicrophoneRecordingAvailability.resolve(isRecording: true, noMic: true),
            .recordingActive,
        )
    }

    func testEveryBlockedCaseExplainsItself() {
        // A disabled menu item with no reason is indistinguishable from a bug.
        for state in [MicrophoneRecordingAvailability.recordingActive, .blockedByNoMicSetting] {
            XCTAssertNotNil(state.disabledReason, "\(state) gives the user nothing to act on")
        }
    }

    func testTheSettingReasonNamesTheSettingItself() {
        // Someone who set this months ago has to be able to find it again.
        let reason = MicrophoneRecordingAvailability.blockedByNoMicSetting.disabledReason
        XCTAssertEqual(reason?.contains("No Microphone"), true)
    }
}
