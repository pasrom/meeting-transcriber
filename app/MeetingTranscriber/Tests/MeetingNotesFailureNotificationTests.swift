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
    }

    /// The fixed sentence of the kind, never the provider's own text.
    func testFailedNotesAreAnnouncedWithTheKindOfFailure() {
        var job = makeJob()
        job.notesFailure = MeetingNotesFailure(ProtocolError.connectionFailed("The request timed out."))
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: true)
        XCTAssertEqual(note.title, "Meeting Notes Failed")
        XCTAssertEqual(note.body, "\"Sprint Review\": The notes provider could not be reached. The transcript is saved.")
    }

    func testWithTheSettingOffAFailureIsAPlainTranscript() {
        var job = makeJob()
        job.notesFailure = .timedOut
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: false)
        XCTAssertEqual(note.title, "Transcript Saved")
        XCTAssertEqual(note.body, "Sprint Review")
    }

    /// A notes-only run (a retry, or notes from a picked transcript) saved no
    /// transcript, so a failure of it does not say that one is saved. The way
    /// to fix it still follows.
    func testAFailedNotesOnlyRunClaimsNoSavedTranscript() {
        var job = makeJob()
        job.generatesNotesOnly = true
        job.notesFailure = .providerUnreachable
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: true)
        XCTAssertEqual(note.title, "Meeting Notes Failed")
        XCTAssertEqual(note.body, "\"Sprint Review\": The notes provider could not be reached.")

        job.notesFailure = .claudeSignedOut
        XCTAssertEqual(
            PipelineQueue.doneNotification(for: job, announceNotesFailure: true).body,
            "\"Sprint Review\": The Claude CLI is not signed in. Run claude in Terminal and sign in with /login.",
        )
    }

    // MARK: - Kind of failure

    #if !APPSTORE
        func testASignedOutClaudeCLIGetsTheWayToFixIt() {
            var job = makeJob()
            job.notesFailure = MeetingNotesFailure(ProtocolError.cliFailed(1, "Not logged in · Please run /login"))
            let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: true)
            XCTAssertEqual(
                note.body,
                "\"Sprint Review\": The Claude CLI is not signed in. The transcript is saved. "
                    + "Run claude in Terminal and sign in with /login.",
            )
        }

        func testAnotherClaudeCLIErrorGetsNoSignInHint() {
            XCTAssertEqual(MeetingNotesFailure(ProtocolError.cliFailed(1, "Rate limit reached")), .claudeFailed)
        }
    #endif

    /// A 401 from an OpenAI-compatible endpoint whose body talks about logging
    /// in and authentication: not the Claude CLI, so no hint to sign in there.
    func testAnAuthFailureOfAnotherProviderGetsNoHint() {
        let failure = MeetingNotesFailure(ProtocolError.httpError(401, "authentication failed, please log in: /login"))
        XCTAssertEqual(failure, .providerRejected)
        XCTAssertNil(failure.hint)
    }

    /// The server's body (up to 500 characters, line breaks included) reaches
    /// neither the job nor the notification, through the catch in
    /// `generateProtocol`.
    func testTheServerBodyReachesNeitherTheJobNorTheNotification() async throws {
        let dir = try makeTempDirectory(prefix: "notes_failure_body")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let generator = MockProtocolGen()
        generator.shouldThrow = true
        generator.errorToThrow = ProtocolError.httpError(500, "server-body line one\nline two " + String(repeating: "x", count: 470))
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: dir, logDir: dir,
        )
        let job = makeJob()
        queue.insertJobForTesting(job)

        try await queue.generateProtocol(jobID: job.id, transcript: "[Speaker A] Hello", title: job.meetingTitle, protocolsDir: dir)

        let failed = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(failed.notesFailure, .providerRejected)
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(failed), encoding: .utf8))
        XCTAssertFalse(stored.contains("server-body"), "the job keeps the server's body")
        let note = PipelineQueue.doneNotification(for: failed, announceNotesFailure: true)
        XCTAssertFalse(note.body.contains("server-body"), note.body)
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
