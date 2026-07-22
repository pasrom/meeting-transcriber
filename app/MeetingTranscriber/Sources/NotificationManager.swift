import Foundation
import os.log
import UserNotifications

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NotificationManager")

/// Sends macOS notifications for meeting state transitions. Marked
/// `@unchecked Sendable` because:
/// - `UNUserNotificationCenter` is thread-safe per Apple's docs
/// - `isSetUp` is written exactly once in `setUp()` (called from the
///   `@main` scene) and read thereafter, so no real race
/// `@MainActor` would be cleaner but conflicts with the
/// `UNUserNotificationCenterDelegate` callbacks, which the framework
/// invokes from arbitrary queues.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, AppNotifying, @unchecked Sendable {
    static let shared = NotificationManager()

    private(set) var isSetUp = false

    // MARK: - Browser meeting consent prompt (issue #503)

    /// Notification category + action identifiers for the "record this browser
    /// meeting?" prompt. The category is registered in `setUp()`; the action
    /// identifier the user taps maps to a Bool via `consentGranted(for:)`.
    static let consentCategoryID = "BROWSER_MEETING_CONSENT"
    static let recordActionID = "BROWSER_MEETING_RECORD"
    static let ignoreActionID = "BROWSER_MEETING_IGNORE"
    /// An unanswered prompt counts as "ignore" after this long, so a missed
    /// prompt doesn't block the watch loop indefinitely. Independent of
    /// `BrowserConsentPolicy.cooldown` (post-decline re-prompt suppression),
    /// which happens to share this value — the two are separate knobs, don't
    /// unify them.
    static let consentPromptTimeout: TimeInterval = 60

    /// Owns the consent prompt's register/resolve/timeout/race logic (unit-tested
    /// in `ConsentPromptCoordinatorTests`); this class only wires the
    /// UNUserNotificationCenter add + delegate callback to it.
    private let consentCoordinator = ConsentPromptCoordinator(timeout: NotificationManager.consentPromptTimeout)

    #if !APPSTORE
        /// Bounded in-memory log of every notification posted through
        /// `notify(...)`, read by the dev-only debug RPC `/state.notifications`
        /// snapshot (via the `AppNotifying.recentNotifications` conformance).
        /// Gated out of the App Store variant, which has no RPC reader.
        let recentNotificationsLog = NotificationRingBuffer()

        var recentNotifications: [NotificationRingBuffer.Entry] {
            recentNotificationsLog.entries
        }
    #endif

    /// The notification center behind a port (so posting + registration are
    /// testable against a fake) and the "can we deliver?" check (a real app
    /// bundle is required — `Bundle.main.bundleIdentifier` is nil in `swift
    /// test`). Both injected; production uses the real system center + the bundle
    /// check, tests inject a fake scheduler and flip `canDeliver`.
    private let scheduler: any NotificationScheduling
    private let canDeliver: @Sendable () -> Bool

    init(
        scheduler: any NotificationScheduling = SystemNotificationScheduler(),
        canDeliver: @escaping @Sendable () -> Bool = { Bundle.main.bundleIdentifier != nil },
    ) {
        self.scheduler = scheduler
        self.canDeliver = canDeliver
        super.init()
    }

    /// Set up delegate and request permission. Must be called after the app bundle is loaded.
    func setUp() {
        guard !isSetUp else { return }
        // UNUserNotificationCenter crashes without a proper app bundle.
        guard canDeliver() else {
            logger.warning("Skipping setup — notifications not deliverable")
            return
        }
        isSetUp = true
        scheduler.setDelegate(self)
        scheduler.setCategories([Self.makeConsentCategory()])
        scheduler.requestAuthorization()
    }

    func notify(title: String, body: String) {
        let deliverable = isSetUp && canDeliver()

        #if !APPSTORE
            // Record before the delivery guard so the app's *decision* to notify
            // is captured even in headless/test contexts where
            // `UNUserNotificationCenter` (which needs a real app bundle) is
            // absent. The `delivered` flag preserves the distinction: RPC
            // consumers asserting a user-VISIBLE warning must check it.
            recentNotificationsLog.record(title: title, body: body, delivered: deliverable)
        #endif

        guard deliverable else { return }

        scheduler.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: Self.makeNotificationContent(title: title, body: body),
            trigger: nil,
        ))
    }

    /// Pure builder for a notification's `UNMutableNotificationContent` (title,
    /// body, sound, and optional category). Split out so the content mapping is
    /// unit-testable without a real notification center.
    static func makeNotificationContent(
        title: String, body: String, categoryID: String? = nil,
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryID { content.categoryIdentifier = categoryID }
        return content
    }

    /// Pure function: determines notification content for a state transition.
    /// Returns nil if no notification should be sent.
    static func notificationContent(
        for state: TranscriberState,
        status: TranscriberStatus,
    ) -> (title: String, body: String)? {
        switch state {
        case .recording:
            let meetingTitle = status.meeting?.title ?? "Unknown"
            let app = status.meeting?.app ?? ""
            return ("Meeting Detected", "Recording: \(meetingTitle) (\(app))")

        case .protocolReady:
            let meetingTitle = status.meeting?.title ?? "Meeting"
            return ("Protocol Ready", "Protocol for \"\(meetingTitle)\" is ready.")

        case .waitingForSpeakerNames:
            return ("Name Speakers", "Speakers detected — open the app to assign names")

        case .error:
            if let error = status.error {
                return ("Transcriber Error", error)
            }
            return nil

        default:
            return nil
        }
    }

    /// Handle state transitions and send appropriate notifications.
    func handleTransition(
        from _: TranscriberState?,
        to newState: TranscriberState,
        status: TranscriberStatus,
    ) {
        if let content = Self.notificationContent(for: newState, status: status) {
            notify(title: content.title, body: content.body)
        }
    }

    // MARK: - Consent prompt (issue #503)

    /// The "record this browser meeting?" category with Record / Ignore actions.
    static func makeConsentCategory() -> UNNotificationCategory {
        let record = UNNotificationAction(identifier: recordActionID, title: "Record", options: [.foreground])
        let ignore = UNNotificationAction(identifier: ignoreActionID, title: "Ignore", options: [])
        return UNNotificationCategory(
            identifier: consentCategoryID,
            actions: [record, ignore],
            intentIdentifiers: [],
            options: [],
        )
    }

    /// Pure mapping: only the explicit Record action grants consent. Ignore, a
    /// swipe-away dismiss, and the default body tap all decline.
    static func consentGranted(for actionIdentifier: String) -> Bool {
        actionIdentifier == recordActionID
    }

    /// Post an actionable "record this browser meeting?" prompt and await the
    /// user's choice (issue #503). Returns false when notifications can't be
    /// delivered (no bundle / not set up) so we never record without a visible
    /// prompt, and false on timeout/ignore/dismiss.
    @MainActor
    func askToRecord(title: String, body: String) async -> Bool {
        guard isSetUp, canDeliver() else { return false }
        let id = UUID().uuidString
        return await consentCoordinator.awaitDecision(id: id) { [self] in
            postConsentNotification(id: id, title: title, body: body)
        }
    }

    /// Resolve a parked browser-consent prompt programmatically (the debug-RPC
    /// `confirmBrowserConsent` hook, issue #503) — an automated e2e driver can't
    /// click the macOS notification, so it answers the parked prompt through
    /// this instead. Returns whether a prompt was actually waiting. Touches only
    /// the lock-guarded coordinator, so it's safe from any thread with no
    /// MainActor hop (unlike the scene actions).
    func resolveBrowserConsent(granted: Bool) -> Bool {
        consentCoordinator.resolvePending(granted: granted)
    }

    /// Post the actionable consent notification (the request-building is the pure
    /// `makeNotificationContent`; only the `scheduler.add` is I/O). The decision
    /// itself is driven by `didReceive` / the coordinator timeout, whichever
    /// resolves first.
    private func postConsentNotification(id: String, title: String, body: String) {
        scheduler.add(UNNotificationRequest(
            identifier: id,
            content: Self.makeNotificationContent(title: title, body: body, categoryID: Self.consentCategoryID),
            trigger: nil,
        ))
    }

    /// Resolve a parked consent prompt from a notification response's primitives.
    /// The delegate callback unwraps the framework `UNNotificationResponse` (which
    /// has no public initialiser) into these, so the id + grant mapping stays
    /// unit-testable without constructing a real response.
    func resolveConsent(responseIdentifier: String, actionIdentifier: String) {
        consentCoordinator.resolve(
            id: responseIdentifier,
            granted: Self.consentGranted(for: actionIdentifier),
        )
    }

    // Handle a tapped consent action (or a dismiss) → resolve the prompt.
    // swiftlint:disable:next async_without_await
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        resolveConsent(
            responseIdentifier: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier,
        )
    }

    // Show notifications even when app is in foreground
    // swiftlint:disable:next async_without_await
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
