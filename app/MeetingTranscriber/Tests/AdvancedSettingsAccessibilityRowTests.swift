@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The Accessibility row in Settings → Advanced follows the build's capability
/// (`PermissionHealthCheck.accessibilityApplies`). The test sets the value
/// both ways instead of relying on the build flag, so both answers are
/// covered in either variant of the suite. Split out of `SettingsViewTests`, which sits at the
/// 600-line cap.
@MainActor
final class AdvancedSettingsAccessibilityRowTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite, same pattern as the sibling
    /// settings suites.
    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "AdvancedSettingsAccessibilityRowTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = DefaultsSuite.open(testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(testSuiteName)
        defaults = nil
        testSuiteName = nil
        try await super.tearDown()
    }

    func testAccessibilityRowFollowsTheBuildCapability() throws {
        let shown = try AdvancedSettingsView(
            settings: AppSettings(defaults: defaults),
            showsAccessibility: true,
        ).inspect()
        XCTAssertNoThrow(try shown.find(viewWithAccessibilityIdentifier: A11yID.accessibilityPermissionRow))

        let hidden = try AdvancedSettingsView(
            settings: AppSettings(defaults: defaults),
            showsAccessibility: false,
        ).inspect()
        XCTAssertThrowsError(try hidden.find(viewWithAccessibilityIdentifier: A11yID.accessibilityPermissionRow))
    }
}
