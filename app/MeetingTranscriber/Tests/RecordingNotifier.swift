@testable import MeetingTranscriber

// MARK: - AppNotifying spy

/// Records all notify() calls for assertions.
///
/// Its own file rather than another block in `TestHelpers.swift`, which sits on
/// the 600-line `file_length` cap: this double grows whenever `AppNotifying`
/// does, so it is the piece under pressure.
final class RecordingNotifier: AppNotifying {
    private(set) var calls: [(title: String, body: String)] = []

    /// What `notificationVisibility()` reports. Defaults to the protocol's
    /// own default so existing users of this double are unaffected.
    var reportedVisibility: NotificationVisibility = .unread

    func notify(title: String, body: String) {
        calls.append((title: title, body: body))
    }

    // swiftlint:disable async_without_await
    @MainActor
    func notificationVisibility() async -> NotificationVisibility {
        reportedVisibility
    }

    // swiftlint:enable async_without_await
}
