@testable import MeetingTranscriber
import XCTest

/// `RecordingSource` replaced a `(appPID: pid_t, noMic: Bool)` pair that could
/// describe a recording of nothing. These pin the two questions every consumer
/// asks of it: which process to tap, and which channels the session opens. The
/// permission gate and the channel-health monitors both key on the latter, so a
/// wrong answer here is a wrong refusal or a false silence alarm.
final class RecordingSourceTests: XCTestCase {
    // MARK: - Which process gets tapped

    func testAppSourcesCarryTheirTargetPID() {
        XCTAssertEqual(RecordingSource.appAndMic(pid: 4321).appPID, 4321)
        XCTAssertEqual(RecordingSource.appOnly(pid: 4321).appPID, 4321)
    }

    func testMicOnlyHasNoTargetPID() {
        XCTAssertNil(RecordingSource.micOnly.appPID)
    }

    // MARK: - Which channels the session opens

    func testCapturesAppAudioOnlyWhenThereIsATarget() {
        XCTAssertTrue(RecordingSource.appAndMic(pid: 1).capturesAppAudio)
        XCTAssertTrue(RecordingSource.appOnly(pid: 1).capturesAppAudio)
        XCTAssertFalse(RecordingSource.micOnly.capturesAppAudio)
    }

    func testCapturesMicrophoneForEverythingButTheAppOnlyCase() {
        XCTAssertTrue(RecordingSource.appAndMic(pid: 1).capturesMicrophone)
        XCTAssertFalse(RecordingSource.appOnly(pid: 1).capturesMicrophone)
        XCTAssertTrue(RecordingSource.micOnly.capturesMicrophone)
    }

    func testEveryCaseCapturesSomething() {
        // The state this type exists to rule out: a source that opens neither
        // channel. If a future case forgets one, this is what catches it.
        for source: RecordingSource in [.appAndMic(pid: 1), .appOnly(pid: 1), .micOnly] {
            XCTAssertTrue(
                source.capturesAppAudio || source.capturesMicrophone,
                "\(source) would record nothing",
            )
        }
    }

    // MARK: - The projection the health monitors consume

    func testCapturedChannelsMirrorsEachCase() {
        // A transposition here inverts the whole topology fix silently: the
        // monitors would suppress the channel that exists and report the one
        // that does not, and every assertion about them would still pass.
        XCTAssertEqual(RecordingSource.appAndMic(pid: 1).capturedChannels, .micAndApp)
        XCTAssertEqual(RecordingSource.appOnly(pid: 1).capturedChannels, .appOnly)
        XCTAssertEqual(RecordingSource.micOnly.capturedChannels, .micOnly)
    }

    func testCapturedChannelsAgreesWithTheSourceItProjects() {
        // The projection and the source must answer the same two questions the
        // same way; they are read by different layers.
        for source: RecordingSource in [.appAndMic(pid: 1), .appOnly(pid: 1), .micOnly] {
            XCTAssertEqual(source.capturedChannels.mic, source.capturesMicrophone, "\(source)")
            XCTAssertEqual(source.capturedChannels.app, source.capturesAppAudio, "\(source)")
        }
    }

    // MARK: - Logging

    func testLogDescriptionNamesThePIDSoLogsStayGreppable() {
        // `PID 1234` has to find every line about that recording, whichever
        // subsystem wrote it.
        XCTAssertEqual(RecordingSource.appAndMic(pid: 1234).logDescription, "PID 1234")
        XCTAssertEqual(RecordingSource.appOnly(pid: 1234).logDescription, "PID 1234")
    }

    func testLogDescriptionSaysSoWhenThereIsNoTarget() {
        XCTAssertEqual(RecordingSource.micOnly.logDescription, "microphone only")
    }

    // MARK: - Deriving the source from the user's settings

    func testAppRecordingKeepsTheMicrophoneByDefault() {
        XCTAssertEqual(RecordingSource.forApp(pid: 99, noMic: false), .appAndMic(pid: 99))
    }

    func testAppRecordingDropsTheMicrophoneWhenTheUserAskedFor() {
        // "No Microphone (app audio only)" in Settings.
        XCTAssertEqual(RecordingSource.forApp(pid: 99, noMic: true), .appOnly(pid: 99))
    }
}
