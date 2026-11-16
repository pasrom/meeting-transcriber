@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The storage-limit controls in Settings → Output write back to the settings.
@MainActor
final class RecordingStorageLimitSettingsViewTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "RecordingStorageLimitSettingsViewTests-\(getpid())-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(suiteName)
        suiteName = nil
        try await super.tearDown()
    }

    private func makeSettings() throws -> AppSettings {
        try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suiteName)))
    }

    func testToggleWritesBackToSettings() throws {
        let settings = try makeSettings()
        settings.recordingStorageLimitEnabled = false
        let view = OutputSettingsView(settings: settings)

        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.recordingStorageLimitToggle)
            .find(ViewType.Toggle.self)
        try toggle.tap()

        XCTAssertTrue(settings.recordingStorageLimitEnabled)
    }

    /// The second Stepper of the Output tab, after the retention days.
    func testStepperWritesBackToSettings() throws {
        let settings = try makeSettings()
        settings.recordingStorageLimitEnabled = true
        settings.recordingStorageLimitGB = 10
        let view = OutputSettingsView(settings: settings)

        let steppers = try view.inspect().findAll(ViewType.Stepper.self)
        XCTAssertEqual(steppers.count, 2)
        try steppers[1].increment()

        XCTAssertEqual(settings.recordingStorageLimitGB, 11)
    }
}
