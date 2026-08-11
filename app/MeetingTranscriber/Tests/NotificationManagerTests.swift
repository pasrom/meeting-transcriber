@testable import MeetingTranscriber
import UserNotifications
import XCTest

final class NotificationManagerTests: XCTestCase {
    // MARK: - isSetUp starts false

    func testIsSetUpFalseByDefault() {
        let manager = NotificationManager()
        XCTAssertFalse(manager.isSetUp)
    }

    // MARK: - notify without setUp is no-op

    func testNotifyWithoutSetUpDoesNotCrash() {
        let manager = NotificationManager()
        // isSetUp is false — notify should silently return
        manager.notify(title: "Test", body: "Should be ignored")
        XCTAssertFalse(manager.isSetUp)
    }

    // MARK: - handleTransition without setUp is no-op

    func testHandleTransitionWithoutSetUpDoesNotCrash() {
        let manager = NotificationManager()
        let status = TranscriberStatus(
            version: 1, timestamp: "2026-03-03T10:00:00",
            state: .recording, detail: "",
            meeting: MeetingInfo(app: "Teams", title: "Standup", pid: 1),
            protocolPath: nil, error: nil, audioPath: nil, pid: nil,
        )
        // recording state would normally trigger a notification, but setUp was
        // never called so notify() should be a no-op
        manager.handleTransition(from: nil, to: .recording, status: status)
    }

    func testHandleTransitionNoNotificationForIdle() {
        let manager = NotificationManager()
        let status = TranscriberStatus(
            version: 1, timestamp: "2026-03-03T10:00:00",
            state: .idle, detail: "", meeting: nil,
            protocolPath: nil, error: nil, audioPath: nil, pid: nil,
        )
        manager.handleTransition(from: nil, to: .idle, status: status)
    }

    func testHandleTransitionSameStateTwice() {
        let manager = NotificationManager()
        let status = TranscriberStatus(
            version: 1, timestamp: "2026-03-03T10:00:00",
            state: .recording, detail: "", meeting: nil,
            protocolPath: nil, error: nil, audioPath: nil, pid: nil,
        )
        manager.handleTransition(from: nil, to: .recording, status: status)
        manager.handleTransition(from: .recording, to: .recording, status: status)
    }

    // MARK: - shared singleton

    func testSharedIsSingleton() {
        let a = NotificationManager.shared
        let b = NotificationManager.shared
        XCTAssertIdentical(a, b)
    }

    #if !APPSTORE

        // MARK: - notify records into the ring buffer (RPC observability chokepoint)

        /// The buffer records ahead of the delivery guard, so a notify() call is
        /// captured even when `setUp()` never ran (no app bundle in the test host)
        /// BUT is marked undelivered — the entry means "the app decided to
        /// notify", not "the user saw it". This is the single chokepoint the
        /// debug RPC `/state.notifications` snapshot reads, so every caller is
        /// observable without touching call sites.
        func testNotifyRecordsUnpostedEntryWhenSetUpNeverRan() {
            let manager = NotificationManager()
            XCTAssertFalse(manager.isSetUp)

            manager.notify(title: "Silent Recording", body: "Both channels silent")
            manager.notify(title: "Meeting Detected", body: "Recording: Standup (Teams)")

            let entries = manager.recentNotificationsLog.entries
            XCTAssertEqual(entries.map(\.title), ["Silent Recording", "Meeting Detected"])
            XCTAssertEqual(entries.map(\.body), ["Both channels silent", "Recording: Standup (Teams)"])
            XCTAssertEqual(entries.map(\.posted), [false, false], "delivery guard failed, so entries must be marked unposted")
        }

        /// The `AppNotifying.recentNotifications` conformance exposes the same
        /// entries the buffer holds — this is what `AppState.rpcStateSnapshot()`
        /// reads through the injected notifier.
        func testRecentNotificationsConformanceMirrorsBuffer() {
            let manager = NotificationManager()
            manager.notify(title: "Silent Recording", body: "Both channels silent")

            XCTAssertEqual(manager.recentNotifications, manager.recentNotificationsLog.entries)
        }
    #endif

    // MARK: - notificationContent (pure helper)

    func testNotificationContentRecordingUsesMeetingTitleAndApp() {
        let content = NotificationManager.notificationContent(
            for: .recording,
            status: statusWithMeeting(app: "Teams", title: "Standup"),
        )
        XCTAssertEqual(content?.title, "Meeting Detected")
        XCTAssertEqual(content?.body, "Recording: Standup (Teams)")
    }

    func testNotificationContentRecordingFallsBackWhenMeetingMissing() {
        // Defensive: if a recording-state notification ever fires without a
        // meeting attached (shouldn't happen in production), the body still
        // renders rather than crashing.
        let content = NotificationManager.notificationContent(
            for: .recording,
            status: statusWithNoMeeting(),
        )
        XCTAssertEqual(content?.title, "Meeting Detected")
        XCTAssertEqual(content?.body, "Recording: Unknown ()")
    }

    func testNotificationContentProtocolReady() {
        let content = NotificationManager.notificationContent(
            for: .protocolReady,
            status: statusWithMeeting(app: "Zoom", title: "Retro"),
        )
        XCTAssertEqual(content?.title, "Protocol Ready")
        XCTAssertEqual(content?.body, "Protocol for \"Retro\" is ready.")
    }

    func testNotificationContentProtocolReadyFallsBackToMeetingLabel() {
        let content = NotificationManager.notificationContent(
            for: .protocolReady,
            status: statusWithNoMeeting(),
        )
        XCTAssertEqual(content?.body, "Protocol for \"Meeting\" is ready.")
    }

    func testNotificationContentWaitingForSpeakerNames() {
        let content = NotificationManager.notificationContent(
            for: .waitingForSpeakerNames,
            status: statusWithNoMeeting(),
        )
        XCTAssertEqual(content?.title, "Name Speakers")
        XCTAssertFalse(content?.body.isEmpty ?? true)
    }

    func testNotificationContentErrorWithMessage() {
        let status = TranscriberStatus(
            version: 1, timestamp: "2026-05-21T10:00:00",
            state: .error, detail: "", meeting: nil,
            protocolPath: nil, error: "disk full", audioPath: nil, pid: nil,
        )
        let content = NotificationManager.notificationContent(for: .error, status: status)
        XCTAssertEqual(content?.title, "Transcriber Error")
        XCTAssertEqual(content?.body, "disk full")
    }

    func testNotificationContentErrorWithoutMessageReturnsNil() {
        // No error string attached → suppress the notification entirely.
        // Avoids a "Transcriber Error" banner with a blank body.
        let content = NotificationManager.notificationContent(
            for: .error,
            status: statusWithNoMeeting(),
        )
        XCTAssertNil(content)
    }

    func testNotificationContentReturnsNilForSilentStates() {
        // .idle / .watching / .transcribing / .generatingProtocol /
        // .waitingForSpeakerCount / .recordingDone all fall into the
        // `default` branch — no notification.
        for state: TranscriberState in [
            .idle, .watching, .transcribing, .generatingProtocol,
            .waitingForSpeakerCount, .recordingDone,
        ] {
            XCTAssertNil(
                NotificationManager.notificationContent(
                    for: state,
                    status: statusWithNoMeeting(),
                ),
                "Expected no notification for state \(state)",
            )
        }
    }

    // MARK: - Browser consent prompt (issue #503)

    func testConsentGrantedOnlyForRecordAction() {
        XCTAssertEqual(NotificationManager.consentAnswer(for: NotificationManager.recordActionID), .granted)
    }

    func testNeverActionIsItsOwnAnswerNotADecline() {
        // The distinction the deny list rests on: a decline is about this call
        // and expires with the cooldown, Never is about the app and does not.
        // Mapping Never onto .declined would re-prompt ten minutes later.
        XCTAssertEqual(NotificationManager.consentAnswer(for: NotificationManager.neverActionID), .never)
        XCTAssertFalse(ConsentAnswer.never.isGranted)
    }

    func testConsentDeclinedForIgnoreDismissAndDefault() {
        XCTAssertEqual(NotificationManager.consentAnswer(for: NotificationManager.ignoreActionID), .declined)
        XCTAssertEqual(NotificationManager.consentAnswer(for: UNNotificationDismissActionIdentifier), .declined)
        XCTAssertEqual(NotificationManager.consentAnswer(for: UNNotificationDefaultActionIdentifier), .declined)
        XCTAssertEqual(NotificationManager.consentAnswer(for: "something-else"), .declined)
    }

    func testConsentCategoryHasRecordIgnoreAndNeverActions() {
        let category = NotificationManager.makeConsentCategory()
        XCTAssertEqual(category.identifier, NotificationManager.consentCategoryID)
        XCTAssertEqual(
            category.actions.map(\.identifier),
            [
                NotificationManager.recordActionID,
                NotificationManager.ignoreActionID,
                NotificationManager.neverActionID,
            ],
        )
        XCTAssertEqual(category.actions.map(\.title), ["Record", "Ignore", "Never for this app"])
    }

    /// Neither action may carry `.foreground`. The delegate callback fires
    /// either way, so the flag buys nothing and costs the user their meeting
    /// window: tapping Record activates the app, pulling focus away from the
    /// call they just consented to keep having. On a machine with several
    /// bundles registered for the same identifier it is worse than useless,
    /// because LaunchServices activates whichever copy it considers canonical
    /// rather than the running one.
    func testConsentActionsDoNotActivateTheApp() {
        let category = NotificationManager.makeConsentCategory()
        for action in category.actions {
            XCTAssertFalse(
                action.options.contains(.foreground),
                "\(action.identifier) must not steal focus from the meeting",
            )
        }
    }

    func testAskToRecordDeclinesWhenNotSetUp() async {
        // No app bundle / setUp never ran → we can't show a prompt, so default
        // to "don't record" rather than recording without asking.
        let manager = NotificationManager()
        let answer = await manager.askToRecord(title: "Browser meeting", body: "Record?")
        XCTAssertEqual(answer, .declined)
    }

    func testDefaultNotifierDeniesConsent() async {
        // The AppNotifying default (a notifier with no real prompt, e.g.
        // SilentNotifier) denies consent, so a browser meeting never records
        // without a visible prompt.
        let answer = await SilentNotifier().askToRecord(title: "Browser meeting", body: "Record?")
        XCTAssertEqual(answer, .declined)
    }

    // MARK: - Helpers

    private func statusWithMeeting(app: String, title: String) -> TranscriberStatus {
        TranscriberStatus(
            version: 1, timestamp: "2026-05-21T10:00:00",
            state: .recording, detail: "",
            meeting: MeetingInfo(app: app, title: title, pid: 1),
            protocolPath: nil, error: nil, audioPath: nil, pid: nil,
        )
    }

    private func statusWithNoMeeting() -> TranscriberStatus {
        TranscriberStatus(
            version: 1, timestamp: "2026-05-21T10:00:00",
            state: .idle, detail: "", meeting: nil,
            protocolPath: nil, error: nil, audioPath: nil, pid: nil,
        )
    }
}
