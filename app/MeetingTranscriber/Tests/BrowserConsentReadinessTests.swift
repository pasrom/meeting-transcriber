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
///
/// Authorisation alone is not that decision. A user can be `.authorized` and
/// still never see the prompt, which is exactly the state the field report came
/// from, so the input here is the full `NotificationVisibility`.
final class BrowserConsentReadinessTests: XCTestCase {
    /// Everything permissive unless a test says otherwise, so each case names
    /// only the one setting it is about.
    private func visibility(
        authorization: UNAuthorizationStatus = .authorized,
        alert: UNNotificationSetting = .enabled,
        alertStyle: UNAlertStyle = .banner,
        timeSensitive: UNNotificationSetting = .enabled,
        scheduledDelivery: UNNotificationSetting = .disabled,
    ) -> NotificationVisibility {
        NotificationVisibility(
            authorization: authorization,
            alert: alert,
            alertStyle: alertStyle,
            timeSensitive: timeSensitive,
            scheduledDelivery: scheduledDelivery,
        )
    }

    func test_toggleOff_neverWarns_whateverTheAuthorizationStatus() {
        for status: UNAuthorizationStatus in [.denied, .notDetermined, .authorized, .provisional] {
            let readiness = BrowserConsentReadiness.evaluate(
                browserMeetingsEnabled: false,
                visibility: visibility(authorization: status),
            )
            XCTAssertEqual(readiness, .disabled, "status \(status.rawValue)")
            XCTAssertNil(readiness.warning, "status \(status.rawValue)")
        }
    }

    func test_authorizedAndVisible_isReadyAndSilent() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(),
        )
        XCTAssertEqual(readiness, .ready)
        XCTAssertNil(readiness.warning)
    }

    func test_denied_warns() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(authorization: .denied),
        )
        XCTAssertEqual(readiness, .denied)
        XCTAssertNotNil(readiness.warning)
    }

    func test_notDetermined_warns() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(authorization: .notDetermined),
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
            visibility: visibility(authorization: .provisional),
        )
        XCTAssertEqual(readiness, .quiet)
        XCTAssertNotNil(readiness.warning)
    }

    // MARK: - Authorised but invisible (issue #543)

    /// The reported state: notifications allowed, alert style set to None. The
    /// prompt lands in Notification Center with no banner and expires on its
    /// timer, so the feature is as dead as with notifications denied, while
    /// every authorisation-based check reports health.
    func test_alertStyleNone_warns_eventhoughAuthorized() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(alertStyle: .none),
        )
        XCTAssertEqual(readiness, .bannersOff)
        XCTAssertNotNil(readiness.warning)
    }

    /// Alerts switched off wholesale is the same failure by a different switch.
    func test_alertsDisabled_warns_eventhoughAuthorized() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(alert: .disabled),
        )
        XCTAssertEqual(readiness, .bannersOff)
    }

    /// `.timeSensitive` is what carries the prompt through Focus. With the
    /// per-app switch off it is a plain banner again: fine on an idle Mac,
    /// invisible during any Focus mode, which is when meetings happen.
    func test_timeSensitiveDisabled_warns() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(timeSensitive: .disabled),
        )
        XCTAssertEqual(readiness, .timeSensitiveOff)
        XCTAssertNotNil(readiness.warning)
    }

    /// `.notSupported` means this build carries no time-sensitive entitlement,
    /// not that the user switched anything off. There is no toggle to point at,
    /// and the prompt still shows whenever no Focus is on, so warning here would
    /// be advice nobody can act on.
    func test_timeSensitiveNotSupported_staysSilent() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(timeSensitive: .notSupported),
        )
        XCTAssertEqual(readiness, .ready)
        XCTAssertNil(readiness.warning)
    }

    /// Precedence: with several problems at once the user gets the one that
    /// blocks everything, not the subtlest one. Denied notifications make the
    /// banner style irrelevant.
    func test_deniedWins_overTheVisibilityProblems() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(
                authorization: .denied,
                alert: .disabled,
                alertStyle: .none,
                timeSensitive: .disabled,
            ),
        )
        XCTAssertEqual(readiness, .denied)
    }

    /// A missing banner beats a missing Focus breakthrough: a prompt that never
    /// appears at all is the worse of the two, and fixing it is the first step.
    func test_bannersOffWins_overTimeSensitiveOff() {
        let readiness = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(alertStyle: .none, timeSensitive: .disabled),
        )
        XCTAssertEqual(readiness, .bannersOff)
    }

    /// Every warning has to name the consequence, not just the state. "Turn on
    /// notifications" without "otherwise browser meetings are never recorded"
    /// reads as optional polish.
    func test_warnings_nameTheConsequence() {
        let cases: [(String, NotificationVisibility)] = [
            ("denied", visibility(authorization: .denied)),
            ("notDetermined", visibility(authorization: .notDetermined)),
            ("provisional", visibility(authorization: .provisional)),
            ("alertStyle none", visibility(alertStyle: .none)),
            ("timeSensitive off", visibility(timeSensitive: .disabled)),
        ]
        for (name, visibility) in cases {
            let readiness = BrowserConsentReadiness.evaluate(
                browserMeetingsEnabled: true,
                visibility: visibility,
            )
            let warning = readiness.warning ?? ""
            XCTAssertTrue(
                warning.lowercased().contains("record"),
                "warning for \(name) must say recording won't happen: \(warning)",
            )
        }
    }

    /// The headline is not one fixed sentence: only the states that stop every
    /// browser meeting may claim that. A prompt that merely loses to Focus is
    /// overstated as "cannot be recorded", and an overstated warning is the kind
    /// users learn to ignore.
    func test_headline_matchesHowTotalTheFailureIs() {
        let dead = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(authorization: .denied),
        )
        let partial = BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: true,
            visibility: visibility(timeSensitive: .disabled),
        )
        XCTAssertNotEqual(dead.headline, partial.headline)
        XCTAssertNil(BrowserConsentReadiness.ready.headline)
        XCTAssertNil(BrowserConsentReadiness.disabled.headline)
    }
}
