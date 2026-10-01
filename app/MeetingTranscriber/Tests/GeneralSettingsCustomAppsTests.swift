@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class GeneralSettingsCustomAppsTests: XCTestCase {
    private let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    private func makeSettings(customApps: [String]) throws -> AppSettings {
        let suiteName = "GeneralSettingsCustomAppsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.watchCustomApps = customApps
        return settings
    }

    func testCustomAppsAreListedByNameIncludingUninstalledOnes() throws {
        let settings = try makeSettings(customApps: ["com.apple.finder", "com.example.not-installed"])
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        XCTAssertNoThrow(try view.inspect().find(text: "Finder"))
        XCTAssertNoThrow(try view.inspect().find(text: "com.example.not-installed"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.watchCustomAppRemove(1)))
    }

    func testRemoveWritesBackAndLeavesTheOtherEntries() throws {
        let settings = try makeSettings(customApps: ["com.apple.finder", "com.example.callapp"])
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.watchCustomAppRemove(0))
            .button()
            .tap()

        XCTAssertEqual(settings.watchCustomApps, ["com.example.callapp"])
    }

    func testAddingAppsSkipsDuplicatesAndNonBundles() throws {
        let settings = try makeSettings(customApps: [])
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        view.addWatchedApps(at: [finderURL, finderURL, URL(fileURLWithPath: "/nonexistent.app")])

        XCTAssertEqual(settings.watchCustomApps, ["com.apple.finder"])
    }
}
