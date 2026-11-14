@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The notification for a meeting whose notes could not be generated. It
/// replaced a plain "Transcript Saved", which hid the failure: with the Claude
/// CLI signed out, every meeting finished that way and nothing said why.
@MainActor
final class MeetingNotesFailureNotificationTests: XCTestCase {
    // MARK: - Setting

    func testOnByDefault() {
        XCTAssertTrue(freshSettings().notifyOnMeetingNotesFailure)
    }

    func testTheChoicePersists() throws {
        let name = "notes-failure-persist-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        let defaults = try XCTUnwrap(DefaultsSuite.open(name))
        AppSettings(defaults: defaults).notifyOnMeetingNotesFailure = false
        XCTAssertFalse(
            AppSettings(defaults: defaults).notifyOnMeetingNotesFailure,
            "the choice has to survive a relaunch",
        )
    }

    func testTheToggleWritesBackToSettings() throws {
        let settings = freshSettings()
        let toggle = try OutputSettingsView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.notifyOnMeetingNotesFailureToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertFalse(settings.notifyOnMeetingNotesFailure)
    }

    // MARK: - Notification

    func testNotesThatWereSavedAreReady() {
        var job = makeJob()
        job.protocolPath = URL(fileURLWithPath: "/tmp/notes.md")
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: true)
        XCTAssertEqual(note.title, "Meeting Notes Ready")
        XCTAssertEqual(note.body, "Sprint Review")
        XCTAssertEqual(note.urgency, .standard)
    }

    func testFailedNotesAreAnnouncedWithTheReason() {
        var job = makeJob()
        job.protocolFailure = "Connection failed: The request timed out."
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: true)
        XCTAssertEqual(note.title, "Meeting Notes Failed")
        XCTAssertEqual(note.body, "\"Sprint Review\": Connection failed: The request timed out. The transcript is saved.")
        XCTAssertEqual(note.urgency, .timeSensitive)
    }

    func testASignedOutClaudeCLIGetsTheWayToFixIt() {
        var job = makeJob()
        job.protocolFailure = "Claude CLI exited with code 1: Not logged in · Please run /login"
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: true)
        XCTAssertTrue(note.body.hasSuffix("Run claude in Terminal and sign in with /login."), note.body)
    }

    func testWithTheSettingOffAFailureIsAPlainTranscript() {
        var job = makeJob()
        job.protocolFailure = "Claude CLI took too long (>10 min)"
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: false)
        XCTAssertEqual(note.title, "Transcript Saved")
        XCTAssertEqual(note.body, "Sprint Review")
        XCTAssertEqual(note.urgency, .standard)
    }

    // MARK: - Fixture

    private func makeJob() -> PipelineJob {
        PipelineJob(meetingTitle: "Sprint Review", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
    }

    private func freshSettings() -> AppSettings {
        let name = "notes-failure-\(UUID().uuidString)"
        let defaults = DefaultsSuite.open(name)!
        // swiftlint:disable:previous force_unwrapping
        addTeardownBlock { DefaultsSuite.remove(name) }
        return AppSettings(defaults: defaults)
    }
}
