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

    func testStepperWritesBackToSettings() throws {
        let settings = try makeSettings()
        settings.recordingStorageLimitEnabled = true
        settings.recordingStorageLimitGB = 10
        let view = OutputSettingsView(settings: settings)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.recordingStorageLimitStepper)
            .find(ViewType.Stepper.self)
            .increment()

        XCTAssertEqual(settings.recordingStorageLimitGB, 11)
    }

    func testStatusIsShownOnlyWhileTheLimitIsOn() throws {
        let settings = try makeSettings()
        settings.recordingStorageLimitEnabled = true
        settings.recordingStorageStatus = RecordingStorageStatus(totalBytes: 2_000_000_000, keptBytes: 0, warning: nil)

        let status = try OutputSettingsView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.recordingStorageStatus)
        XCTAssertEqual(try status.find(ViewType.Text.self).string(), "Recordings use 2 GB.")

        settings.recordingStorageLimitEnabled = false
        XCTAssertThrowsError(
            try OutputSettingsView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.recordingStorageStatus),
        )
    }

    /// The view words the pending deletion against the current time.
    func testStatusSaysDeletingOnceTheDeleteTimeHasPassed() throws {
        let settings = try makeSettings()
        settings.recordingStorageLimitEnabled = true
        let warning = RecordingStorageWarning(since: Date().addingTimeInterval(-7 * 86400), limitBytes: 1, root: nil)
        settings.recordingStorageStatus = RecordingStorageStatus(totalBytes: 2_000_000_000, keptBytes: 0, warning: warning)

        let texts = try OutputSettingsView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.recordingStorageStatus)
            .findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains { $0.contains("are being deleted") }, "\(texts)")
    }
}
