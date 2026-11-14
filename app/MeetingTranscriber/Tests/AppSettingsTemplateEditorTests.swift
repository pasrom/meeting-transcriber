import Foundation
@testable import MeetingTranscriber
import XCTest

/// The app meeting-notes templates open in (`templateEditorBundleIdentifier`):
/// none until one is chosen, then kept across a relaunch until it is forgotten.
final class AppSettingsTemplateEditorTests: XCTestCase {
    func testTheEditorIsAbsentByDefaultAndSurvivesAReload() throws {
        let suite = "AppSettingsTemplateEditorTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.templateEditorBundleIdentifier)

        settings.templateEditorBundleIdentifier = "com.microsoft.VSCode"
        XCTAssertEqual(AppSettings(defaults: defaults).templateEditorBundleIdentifier, "com.microsoft.VSCode")

        settings.templateEditorBundleIdentifier = nil
        XCTAssertNil(AppSettings(defaults: defaults).templateEditorBundleIdentifier)
        XCTAssertNil(defaults.object(forKey: "templateEditorBundleIdentifier"), "forgetting removes the key")
    }
}
