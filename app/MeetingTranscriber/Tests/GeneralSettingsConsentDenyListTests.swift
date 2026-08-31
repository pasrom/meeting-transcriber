@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring test for the never-record list in the General tab.
/// `ConsentDenyListTests` owns the list logic; this only proves the tab
/// renders the rows and that Remove writes back, which is the user's only way
/// to undo a "Never for this app" they regret.
@MainActor
final class GeneralSettingsConsentDenyListTests: XCTestCase {
    private func makeSettings(browserMeetings: Bool, denied: [String]) throws -> AppSettings {
        let suiteName = "GeneralSettingsBrowserDenyListTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.watchBrowserMeetings = browserMeetings
        settings.consentDeniedApps = denied
        return settings
    }

    private func view(browserMeetings: Bool, denied: [String]) throws -> GeneralSettingsView {
        try GeneralSettingsView(
            settings: makeSettings(browserMeetings: browserMeetings, denied: denied),
            notificationVisibility: nil,
        )
    }

    func testSectionIsHiddenWhenNothingIsDenied() throws {
        // A permanently empty box in a settings tab is noise; the section only
        // has a reason to exist once there is something to undo.
        let view = try view(browserMeetings: true, denied: [])
        XCTAssertNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentDenyListSection),
        )
    }

    func testSectionStaysVisibleWhenBrowserWatchingIsOff() throws {
        // Deliberately NOT gated on the browser toggle, though today only
        // browser meetings can add an entry. The gate the deny list hangs off is
        // `requiresRecordingConsent`, a general pattern property, so as soon as
        // another app adopts it a denial made there would become impossible to
        // undo behind a browser-specific switch. Emptiness is the only condition
        // for hiding it.
        let view = try view(browserMeetings: false, denied: ["Fjordfox"])
        XCTAssertNotNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentDenyListSection),
        )
    }

    func testDeniedAppsAreListed() throws {
        let view = try view(browserMeetings: true, denied: ["Fjordfox", "Slack"])
        XCTAssertNotNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentDenyListSection),
        )
        XCTAssertNotNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentDeniedAppRemove(0)),
        )
        XCTAssertNotNil(
            try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentDeniedAppRemove(1)),
        )
    }

    func testRemoveIdentifiersCarryNoAppNames() throws {
        // `GET /ui/tree` publishes identifiers unredacted because they are
        // app-set. An app name here would expose which apps the user refused to
        // have recorded to any holder of the local automation token.
        let view = try view(browserMeetings: true, denied: ["Fjordfox", "Slack"])
        for app in ["Fjordfox", "Slack"] {
            XCTAssertNil(
                try? view.inspect().find(viewWithAccessibilityIdentifier: "consentDeniedAppRemove.\(app)"),
                "\(app): the row identifier must not carry the app name",
            )
        }
    }

    func testRemoveWritesBackAndLeavesTheOtherEntries() throws {
        let settings = try makeSettings(browserMeetings: true, denied: ["Fjordfox", "Slack"])
        let view = GeneralSettingsView(
            settings: settings,
            notificationVisibility: nil,
        )
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.consentDeniedAppRemove(0))
            .button()
            .tap()
        XCTAssertEqual(settings.consentDeniedApps, ["Slack"])
    }
}
