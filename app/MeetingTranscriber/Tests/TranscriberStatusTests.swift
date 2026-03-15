@testable import MeetingTranscriber
import XCTest

final class TranscriberStatusTests: XCTestCase {
    // MARK: - State Labels

    func testIdleLabel() {
        XCTAssertEqual(TranscriberState.idle.label, "Idle")
    }

    func testWatchingLabel() {
        XCTAssertEqual(TranscriberState.watching.label, "Watching for Meetings...")
    }

    func testRecordingLabel() {
        XCTAssertEqual(TranscriberState.recording.label, "Recording")
    }

    func testTranscribingLabel() {
        XCTAssertEqual(TranscriberState.transcribing.label, "Transcribing...")
    }

    func testGeneratingProtocolLabel() {
        XCTAssertEqual(TranscriberState.generatingProtocol.label, "Generating Protocol...")
    }

    func testWaitingForSpeakerCountLabel() {
        XCTAssertEqual(TranscriberState.waitingForSpeakerCount.label, "Speaker Count")
    }

    func testWaitingForSpeakerNamesLabel() {
        XCTAssertEqual(TranscriberState.waitingForSpeakerNames.label, "Name Speakers")
    }

    func testProtocolReadyLabel() {
        XCTAssertEqual(TranscriberState.protocolReady.label, "Protocol Ready")
    }

    func testErrorLabel() {
        XCTAssertEqual(TranscriberState.error.label, "Error")
    }

    // MARK: - State Icons

    func testIdleIcon() {
        XCTAssertEqual(TranscriberState.idle.icon, "waveform.circle")
    }

    func testWatchingIcon() {
        XCTAssertEqual(TranscriberState.watching.icon, "eye.fill")
    }

    func testRecordingIcon() {
        XCTAssertEqual(TranscriberState.recording.icon, "record.circle.fill")
    }

    func testTranscribingIcon() {
        XCTAssertEqual(TranscriberState.transcribing.icon, "waveform")
    }

    func testGeneratingProtocolIcon() {
        XCTAssertEqual(TranscriberState.generatingProtocol.icon, "waveform")
    }

    func testWaitingForSpeakerCountIcon() {
        XCTAssertEqual(TranscriberState.waitingForSpeakerCount.icon, "person.2.wave.2")
    }

    func testWaitingForSpeakerNamesIcon() {
        XCTAssertEqual(TranscriberState.waitingForSpeakerNames.icon, "person.2.fill")
    }

    func testProtocolReadyIcon() {
        XCTAssertEqual(TranscriberState.protocolReady.icon, "checkmark.circle.fill")
    }

    func testErrorIcon() {
        XCTAssertEqual(TranscriberState.error.icon, "exclamationmark.triangle.fill")
    }
}
