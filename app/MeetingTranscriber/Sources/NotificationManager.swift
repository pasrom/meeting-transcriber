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

    override init() {
        super.init()
    }

    /// Set up delegate and request permission. Must be called after the app bundle is loaded.
    func setUp() {
        guard !isSetUp else { return }
        // UNUserNotificationCenter crashes without a proper app bundle
        guard Bundle.main.bundleIdentifier != nil else {
            logger.warning("Skipping setup — no app bundle")
            return
        }
        isSetUp = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.makeConsentCategory()])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
            }
            if !granted {
                logger.warning("Notification permission denied")
            }
        }
    }

    func notify(title: String, body: String) {
        let deliverable = isSetUp && Bundle.main.bundleIdentifier != nil

        #if !APPSTORE
            // Record before the delivery guard so the app's *decision* to notify
            // is captured even in headless/test contexts where
            // `UNUserNotificationCenter` (which needs a real app bundle) is
            // absent. The `delivered` flag preserves the distinction: RPC
            // consumers asserting a user-VISIBLE warning must check it.
            recentNotificationsLog.record(title: title, body: body, delivered: deliverable)
        #endif

        guard deliverable else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil,
        )

        UNUserNotificationCenter.current().add(request)
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
        guard isSetUp, Bundle.main.bundleIdentifier != nil else { return false }
        let id = UUID().uuidString
        return await consentCoordinator.awaitDecision(id: id) { [self] in
            postConsentNotification(id: id, title: title, body: body)
        }
    }

    /// Post the actionable consent notification (the thin UNUserNotificationCenter
    /// adapter — the decision itself is driven by `didReceive` / the coordinator
    /// timeout, whichever resolves first).
    private func postConsentNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.consentCategoryID
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil),
        )
    }

    // Handle a tapped consent action (or a dismiss) → resolve the prompt.
    // swiftlint:disable:next async_without_await
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        consentCoordinator.resolve(
            id: response.notification.request.identifier,
            granted: Self.consentGranted(for: response.actionIdentifier),
        )
    }

    // Show notifications even when app is in foreground
    // swiftlint:disable:next async_without_await
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
