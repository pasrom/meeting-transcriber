@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// The browser-meeting consent prompt is a user notification. If notifications
/// can't reach the user, the feature is not degraded, it is DEAD: detection
/// fires, the prompt parks invisibly, it times out as a decline, and nothing is
/// ever recorded, with the toggle still showing as on.
///
/// Nothing surfaced that before: `canDeliver` only checks for an app bundle,
/// `PermissionHealthCheck` covers mic/screen/accessibility, and the e2e lane
/// answers consent over RPC, which works whether or not a notification was ever
/// shown. This decides when the Settings tab has to say so.
final class BrowserConsentReadinessTests: XCTestCase {
    func test_toggleOff_neverWarns_whateverTheAuthorizationStatus() {
        for status: UNAuthorizationStatus in [.denied, .notDetermined, .authorized, .provisional] {
            let readiness = BrowserConsentReadiness.evaluate(
                browserMeetingsEnabled: false,
                authorization: status,
            )
            XCTAssertEqual(readiness, .disabled, "status \(status.rawValue)")
            XCTAssertNil(readiness.warning, "status \(status.rawValue)")
        }
    }

    func test_authorized_isReadyAndSilent() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            authorization: .authorized,
        )
        XCTAssertEqual(readiness, .ready)
        XCTAssertNil(readiness.warning)
    }

    func test_denied_warns() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            authorization: .denied,
        )
        XCTAssertEqual(readiness, .denied)
        let warning = try? XCTUnwrap(readiness.warning)
        XCTAssertNotNil(warning)
    }

    func test_notDetermined_warns() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            authorization: .notDetermined,
        )
        XCTAssertEqual(readiness, .undetermined)
        XCTAssertNotNil(readiness.warning)
    }

    /// Provisional delivers quietly to Notification Center with no banner. The
    /// consent prompt expires after `NotificationManager.consentPromptTimeout`,
    /// so a prompt the user has to notice on their own is effectively invisible.
    func test_provisional_warns_becauseAQuietPromptExpiresUnseen() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            authorization: .provisional,
        )
        XCTAssertEqual(readiness, .quiet)
        XCTAssertNotNil(readiness.warning)
    }

    /// Every warning has to name the consequence, not just the state. "Turn on
    /// notifications" without "otherwise browser meetings are never recorded"
    /// reads as optional polish.
    func test_warnings_nameTheConsequence() {
        for status: UNAuthorizationStatus in [.denied, .notDetermined, .provisional] {
            let readiness = BrowserConsentReadiness.evaluate(
                browserMeetingsEnabled: true,
                authorization: status,
            )
            let warning = readiness.warning ?? ""
            XCTAssertTrue(
                warning.lowercased().contains("record"),
                "warning for \(status.rawValue) must say recording won't happen: \(warning)",
            )
        }
    }
}
