@testable import MeetingTranscriber
import UserNotifications
import ViewInspector
import XCTest

/// Wiring test for the browser-consent warning: `BrowserConsentReadinessTests`
/// owns the decision logic, this only proves the General tab actually renders it.
///
/// It exists because the failure it guards against is invisible by construction:
/// with notifications denied the browser-meeting toggle looks enabled, detection
/// keeps firing, and nothing is ever recorded. Settings is the only surface that
/// can say so, since warning by notification would depend on the very channel
/// that is broken.
@MainActor
final class GeneralSettingsBrowserWarningTests: XCTestCase {
    /// Isolated defaults per call, torn down by the test itself — the idiom
    /// `makeRPCTestState()` uses, which needs no stored properties, no
    /// setUp/tearDown overrides and no implicitly-unwrapped optionals.
    private func makeSettings(browserMeetings: Bool) throws -> AppSettings {
        let suiteName = "GeneralSettingsBrowserWarningTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.watchBrowserMeetings = browserMeetings
        return settings
    }

    private func warningText(
        browserMeetings: Bool,
        authorization: UNAuthorizationStatus?,
    ) throws -> String? {
        let view = try GeneralSettingsView(
            settings: makeSettings(browserMeetings: browserMeetings),
            updateChecker: nil,
            notificationAuthorization: authorization,
        )
        let found = try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.browserConsentWarning)
        return try found?.text().string()
    }

    func test_deniedNotifications_showTheWarning() throws {
        let text = try warningText(browserMeetings: true, authorization: .denied)
        let warning = try XCTUnwrap(text, "denied notifications must warn in the General tab")
        XCTAssertTrue(warning.lowercased().contains("record"), warning)
    }

    func test_authorizedNotifications_showNoWarning() throws {
        XCTAssertNil(try warningText(browserMeetings: true, authorization: .authorized))
    }

    func test_browserWatchingOff_showsNoWarningEvenWhenDenied() throws {
        XCTAssertNil(try warningText(browserMeetings: false, authorization: .denied))
    }

    /// Before the first permission check the status is unknown. Guessing either
    /// way is wrong: claiming a problem would cry wolf on every launch, and
    /// claiming health would hide a real one, so render nothing until it is read.
    func test_unknownAuthorization_showsNoWarningYet() throws {
        XCTAssertNil(try warningText(browserMeetings: true, authorization: nil))
    }

    /// The General tab is reached through `SettingsView`, so the value has to
    /// survive one more hop than the tests above exercise. Without this, passing
    /// nil (or the wrong property) from the scene would go unnoticed.
    func test_settingsView_forwardsAuthorizationToTheGeneralTab() throws {
        let view = try SettingsView(
            settings: makeSettings(browserMeetings: true),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            updateChecker: nil,
            notificationAuthorization: .denied,
            recognitionStatsLog: RecognitionStatsLog(),
            stageTimingLog: StageTimingLog(),
        )
        let warning = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.browserConsentWarning)
        XCTAssertTrue(try warning.text().string().lowercased().contains("record"))
    }
}
