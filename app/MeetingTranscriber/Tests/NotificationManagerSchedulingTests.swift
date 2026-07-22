@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// Fake `NotificationScheduling` recording what `NotificationManager` posts /
/// registers, so the posting + consent behaviour is testable without a real
/// `UNUserNotificationCenter` (which needs an app bundle absent in `swift test`).
private final class FakeNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [UNNotificationRequest] = []
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) weak var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var authRequested = false

    var added: [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }; return _added
    }

    func add(_ request: UNNotificationRequest) {
        lock.lock(); _added.append(request); lock.unlock()
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        self.delegate = delegate
    }

    func requestAuthorization() {
        authRequested = true
    }
}

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
            // The ring-buffer entry must be flagged delivered — RPC/e2e consumers
            // asserting a user-VISIBLE warning gate on this flag.
            XCTAssertEqual(manager.recentNotifications.map(\.delivered), [true])
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

        manager.resolveConsent(responseIdentifier: posted.identifier, actionIdentifier: NotificationManager.recordActionID)
        let granted = await task.value
        XCTAssertTrue(granted)
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
        let granted = await task.value
        XCTAssertFalse(granted)
    }

    // MARK: - pure content builder

    func testMakeNotificationContentMapsFields() {
        let content = NotificationManager.makeNotificationContent(title: "T", body: "B", categoryID: "CAT")
        XCTAssertEqual(content.title, "T")
        XCTAssertEqual(content.body, "B")
        XCTAssertEqual(content.categoryIdentifier, "CAT")
        XCTAssertEqual(content.sound, .default)
    }

    func testMakeNotificationContentWithoutCategoryLeavesItEmpty() {
        let content = NotificationManager.makeNotificationContent(title: "T", body: "B")
        XCTAssertEqual(content.categoryIdentifier, "")
    }
}
