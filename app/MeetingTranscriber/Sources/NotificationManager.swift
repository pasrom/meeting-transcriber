import Foundation
import UserNotifications

/// Sends macOS notifications for meeting state transitions.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var isSetUp = false

    private override init() {
        super.init()
    }

    /// Set up delegate and request permission. Must be called after the app bundle is loaded.
    func setUp() {
        guard !isSetUp else { return }
        // UNUserNotificationCenter crashes without a proper app bundle
        guard Bundle.main.bundleIdentifier != nil else {
            print("NotificationManager: skipping setup (no app bundle)")
            return
        }
        isSetUp = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("Notification permission error: \(error)")
            }
            if !granted {
                print("Notification permission denied")
            }
        }
    }

    func notify(title: String, body: String) {
        guard isSetUp, Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Pure function: determines notification content for a state transition.
    /// Returns nil if no notification should be sent.
    static func notificationContent(
        for state: TranscriberState,
        status: TranscriberStatus
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
        from oldState: TranscriberState?,
        to newState: TranscriberState,
        status: TranscriberStatus
    ) {
        if let content = Self.notificationContent(for: newState, status: status) {
            notify(title: content.title, body: content.body)
        }
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
