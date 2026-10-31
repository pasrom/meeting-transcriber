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

    func testAddingABrowserIsRefusedWithAReason() throws {
        let settings = try makeSettings(customApps: [])
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let refusals = view.addWatchedApps(at: [safariURL, finderURL, safariURL])

        XCTAssertEqual(settings.watchCustomApps, ["com.apple.finder"])
        XCTAssertEqual(refusals.count, 1)
        XCTAssertTrue(try XCTUnwrap(refusals.first).hasPrefix("Safari is a browser"))
    }

    func testWatchRefusalRejectsOwnBundleAndBrowsersOnly() {
        let webSchemes: [[String: Any]] = [["CFBundleURLSchemes": ["HTTP", "file"]]]
        let chromiumStyle: [String: Any] = [
            "CFBundleURLTypes": webSchemes,
            "CFBundleDocumentTypes": [["LSItemContentTypes": ["public.html"]]],
        ]
        let duckDuckGoStyle: [String: Any] = [
            "CFBundleURLTypes": webSchemes,
            "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["HTM"]]],
        ]
        let mediaPlayer: [String: Any] = [
            "CFBundleURLTypes": webSchemes,
            "CFBundleDocumentTypes": [["LSItemContentTypes": ["public.movie"]]],
        ]
        let callApp: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["callapp"]]]]

        XCTAssertNotNil(GeneralSettingsView.watchRefusal(name: "Chromium", bundleID: "com.example.chromium", info: chromiumStyle))
        XCTAssertNotNil(GeneralSettingsView.watchRefusal(name: "DuckDuckGo", bundleID: "com.example.ddg", info: duckDuckGoStyle))
        XCTAssertNil(GeneralSettingsView.watchRefusal(name: "Player", bundleID: "com.example.player", info: mediaPlayer))
        XCTAssertNil(GeneralSettingsView.watchRefusal(name: "Call App", bundleID: "com.example.callapp", info: callApp))
        XCTAssertNil(GeneralSettingsView.watchRefusal(name: "Plain", bundleID: "com.example.plain", info: [:]))
        XCTAssertNotNil(GeneralSettingsView.watchRefusal(
            name: "MeetingTranscriber",
            bundleID: "com.example.self",
            info: [:],
            ownBundleID: "com.example.self",
        ))
    }

    func testWatchRefusalPointsAppsWithABuiltInToggleAtThatToggle() {
        XCTAssertEqual(
            GeneralSettingsView.watchRefusal(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", info: [:]),
            "WhatsApp has its own toggle above.",
        )
        XCTAssertEqual(
            GeneralSettingsView.watchRefusal(name: "zoom.us", bundleID: "us.zoom.xos", info: ["CFBundleExecutable": "zoom.us"]),
            "Zoom has its own toggle above.",
        )
        XCTAssertNil(GeneralSettingsView.watchRefusal(
            name: "Call App",
            bundleID: "com.example.callapp",
            info: ["CFBundleExecutable": "Call App"],
        ))
    }

    /// Refusal uses the built-in's own `matches`, so a helper is refused only
    /// where that built-in matches helpers; WeChat's deliberately does not.
    func testWatchRefusalAcceptsAHelperItsBuiltInDoesNotMatch() {
        XCTAssertNil(
            GeneralSettingsView.watchRefusal(name: "WeChat Helper", bundleID: "com.tencent.xinWeChat.IPCHelper", info: [:]),
            "WeChat's pattern does not match helpers, so one is not refused, just as the detector keeps it",
        )
    }
}
