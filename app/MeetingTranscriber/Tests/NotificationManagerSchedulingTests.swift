@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// Mutable deliverability so a test can flip `canDeliver` to false *after*
/// `setUp()` has already succeeded — the only way to exercise the `canDeliver`
/// conjunct of `notify`'s deliver guard independently of the `isSetUp` conjunct.
private final class DeliverabilityBox: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) {
        self.value = value
    }
}

@MainActor
final class NotificationManagerSchedulingTests: XCTestCase {
    private func makeManager(deliverable: Bool = true) -> (NotificationManager, FakeNotificationScheduler) {
        let (manager, fake, _) = makeManagerWithBox(deliverable: deliverable)
        return (manager, fake)
    }

    private func makeManagerWithBox(
        deliverable: Bool = true,
    ) -> (NotificationManager, FakeNotificationScheduler, DeliverabilityBox) {
        let fake = FakeNotificationScheduler()
        let box = DeliverabilityBox(deliverable)
        let canDeliver: @Sendable () -> Bool = { box.value }
        let manager = NotificationManager(scheduler: fake, canDeliver: canDeliver)
        return (manager, fake, box)
    }

    // MARK: - setUp

    func testSetUpRegistersDelegateCategoryAndRequestsAuth() {
        let (manager, fake) = makeManager()
        manager.setUp()
        XCTAssertTrue(manager.isSetUp)
        XCTAssertIdentical(fake.delegate, manager)
        XCTAssertTrue(fake.authRequested)
        XCTAssertEqual(fake.categories.map(\.identifier), [NotificationManager.consentCategoryID])
    }

    func testSetUpSkippedWhenNotDeliverable() {
        let (manager, fake) = makeManager(deliverable: false)
        manager.setUp()
        XCTAssertFalse(manager.isSetUp)
        XCTAssertFalse(fake.authRequested)
        XCTAssertNil(fake.delegate)
        XCTAssertTrue(fake.categories.isEmpty)
    }

    // MARK: - notify

    func testNotifyPostsRequestWithMappedContent() {
        let (manager, fake) = makeManager()
        manager.setUp()
        manager.notify(title: "Meeting Detected", body: "Recording: Standup (Teams)")
        XCTAssertEqual(fake.added.count, 1)
        XCTAssertEqual(fake.added.first?.content.title, "Meeting Detected")
        XCTAssertEqual(fake.added.first?.content.body, "Recording: Standup (Teams)")
        #if !APPSTORE
            // The ring-buffer entry must be flagged posted — RPC/e2e consumers
            // asserting a user-VISIBLE warning gate on this flag.
            XCTAssertEqual(manager.recentNotifications.map(\.posted), [true])
        #endif
    }

    func testNotifyDoesNotPostWhenNotSetUp() {
        let (manager, fake) = makeManager()
        // setUp never called → not deliverable regardless of canDeliver.
        manager.notify(title: "Meeting Detected", body: "x")
        XCTAssertTrue(fake.added.isEmpty)
    }

    func testNotifyDoesNotPostWhenSetUpButNotDeliverable() {
        // setUp succeeds (deliverable), then the environment loses deliverability:
        // isSetUp stays true, so this isolates the canDeliver conjunct of notify.
        let (manager, fake, box) = makeManagerWithBox()
        manager.setUp()
        XCTAssertTrue(manager.isSetUp)
        box.value = false
        manager.notify(title: "Meeting Detected", body: "x")
        XCTAssertTrue(fake.added.isEmpty)
    }

    // MARK: - askToRecord consent flow (issue #503)

    /// Awaits the consent notification the manager posts on park, then returns it.
    /// `fake.added` is a synchronous lock-guarded read, so the yield-based
    /// `waitFor` overload drains the parked `askToRecord` Task without sleeping.
    private func firstPostedRequest(from fake: FakeNotificationScheduler) async -> UNNotificationRequest? {
        await waitFor(!fake.added.isEmpty)
        return fake.added.first
    }

    func testAskToRecordPostsConsentNotificationAndRecordActionGrants() async {
        let (manager, fake) = makeManager()
        manager.setUp()
        let task = Task { await manager.askToRecord(title: "Record browser meeting?", body: "A meeting is active.") }

        guard let posted = await firstPostedRequest(from: fake) else {
            XCTFail("no consent notification posted")
            return
        }
        XCTAssertEqual(posted.content.categoryIdentifier, NotificationManager.consentCategoryID)
        XCTAssertEqual(posted.content.title, "Record browser meeting?")
        XCTAssertEqual(posted.content.body, "A meeting is active.")
        // The prompt asks a question that expires after `consentPromptTimeout`.
        // At the default `.active` level macOS renders it as a banner, which any
        // Focus mode suppresses outright — so the question is never seen, times
        // out as a decline, and browser meetings silently never record.
        // `.timeSensitive` is the only level that breaks through Focus
        // (issue #543).
        XCTAssertEqual(posted.content.interruptionLevel, .timeSensitive)

        manager.resolveConsent(responseIdentifier: posted.identifier, actionIdentifier: NotificationManager.recordActionID)
        let answer = await task.value
        XCTAssertEqual(answer, .granted)
    }

    func testAskToRecordIgnoreActionDeclines() async {
        let (manager, fake) = makeManager()
        manager.setUp()
        let task = Task { await manager.askToRecord(title: "Record browser meeting?", body: "A meeting is active.") }

        guard let posted = await firstPostedRequest(from: fake) else {
            XCTFail("no consent notification posted")
            return
        }
        manager.resolveConsent(responseIdentifier: posted.identifier, actionIdentifier: NotificationManager.ignoreActionID)
        let answer = await task.value
        XCTAssertEqual(answer, .declined)
    }

    /// A resolved prompt is withdrawn. macOS clears a notification the user
    /// actually tapped, but not one that expired on its timer or was answered
    /// out of band, so without this every unanswered prompt stays in
    /// Notification Center: 31 dead prompts were sitting on the reported
    /// machine, each one asking about a meeting that ended long ago.
    func testResolvedConsentPromptIsWithdrawn() async {
        let (manager, fake) = makeManager()
        manager.setUp()
        let task = Task { await manager.askToRecord(title: "Record browser meeting?", body: "A meeting is active.") }

        guard let posted = await firstPostedRequest(from: fake) else {
            XCTFail("no consent notification posted")
            return
        }
        XCTAssertTrue(fake.removedIdentifiers.isEmpty, "must not withdraw a prompt that is still parked")

        manager.resolveConsent(responseIdentifier: posted.identifier, actionIdentifier: NotificationManager.ignoreActionID)
        _ = await task.value
        XCTAssertEqual(fake.removedIdentifiers, [posted.identifier])
    }

    // MARK: - urgency

    /// The mapping that makes a capture failure survive Do Not Disturb. The
    /// entitlement that lets macOS honour it is injected at signing time; this
    /// pins the level the app asks for, which is the half we control.
    func testTimeSensitiveUrgencyPostsAtThatInterruptionLevel() {
        let (manager, fake) = makeManager()
        manager.setUp()
        manager.notify(title: "Capture Channel Silent", body: "x", urgency: .timeSensitive)
        XCTAssertEqual(fake.added.first?.content.interruptionLevel, .timeSensitive)
    }

    /// The counterpart, so raising one notification cannot quietly raise all of
    /// them: everything posted without an explicit urgency stays suppressible.
    func testPlainNotifyStaysActive() {
        let (manager, fake) = makeManager()
        manager.setUp()
        manager.notify(title: "Protocol Ready", body: "x")
        XCTAssertEqual(fake.added.first?.content.interruptionLevel, .active)
    }

    // MARK: - pure content builder

    func testMakeNotificationContentMapsFields() {
        let content = NotificationManager.makeNotificationContent(title: "T", body: "B", categoryID: "CAT")
        XCTAssertEqual(content.title, "T")
        XCTAssertEqual(content.body, "B")
        XCTAssertEqual(content.categoryIdentifier, "CAT")
        XCTAssertEqual(content.sound, .default)
        // Overridden only by the consent prompt and the capture-failure
        // notices. A transcript-ready or permission-problem notice has no
        // deadline and must not break through the user's Focus, so the default
        // has to stay `.active`.
        XCTAssertEqual(content.interruptionLevel, .active)
    }

    func testMakeNotificationContentWithoutCategoryLeavesItEmpty() {
        let content = NotificationManager.makeNotificationContent(title: "T", body: "B")
        XCTAssertEqual(content.categoryIdentifier, "")
    }
}
