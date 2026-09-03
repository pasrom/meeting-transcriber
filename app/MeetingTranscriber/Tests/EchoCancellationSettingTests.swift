@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The switch behind echo cancellation, and the one interaction it has with
/// the transcript dedup sitting under it.
@MainActor
final class EchoCancellationSettingTests: XCTestCase {
    private func freshSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "echo-cancel-\(UUID().uuidString)")!
        // swiftlint:disable:previous force_unwrapping
        return AppSettings(defaults: defaults)
    }

    /// Off by default, and it stays off until it has been watched working on
    /// real recordings rather than on an archive with synthetic loudspeaker
    /// echo. The measurement behind it says the trade is favourable; it does
    /// not say the model never fails, and it is known to remove nothing at all
    /// on a minority of recordings without reporting it.
    func testCancellationIsOffByDefault() {
        XCTAssertFalse(freshSettings().echoCancellationEnabled)
    }

    func testTogglePersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "echo-cancel-persist-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.echoCancellationEnabled = true
        XCTAssertTrue(
            AppSettings(defaults: defaults).echoCancellationEnabled,
            "the choice has to survive a relaunch",
        )
    }

    func testToggleWritesBackToSettings() throws {
        let settings = freshSettings()
        let before = settings.echoCancellationEnabled
        let view = AudioSettingsView(settings: settings)
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.echoCancellationToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertEqual(settings.echoCancellationEnabled, !before)
    }

    /// The two remedies do not compose, and cancellation wins. The dedup row
    /// therefore has to look unavailable rather than look like a choice: an
    /// enabled switch that is on and does nothing is the failure this project
    /// has already shipped once.
    func testTheDedupRowIsDisabledWhileCancellationIsOn() throws {
        let settings = freshSettings()
        settings.echoCancellationEnabled = true
        let view = AudioSettingsView(settings: settings)
        let dedup = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.echoDedupToggle)
        XCTAssertTrue(dedup.isDisabled())
    }

    func testTheDedupRowIsAvailableWhenCancellationIsOff() throws {
        let settings = freshSettings()
        settings.echoCancellationEnabled = false
        let view = AudioSettingsView(settings: settings)
        let dedup = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.echoDedupToggle)
        XCTAssertFalse(dedup.isDisabled())
    }

    /// The queue is built once, when watching starts. Copied at construction,
    /// the setting could only take effect after stopping and restarting
    /// watching: the switch said yes and the next recording was processed by a
    /// queue still holding no, which is the shape of "the feature is on and
    /// does nothing" this project keeps having to undo.
    func testTheSettingReachesAQueueThatWasBuiltBeforeItChanged() {
        let settings = freshSettings()
        settings.echoCancellationEnabled = false
        // Bound to a local first: as a trailing argument the formatter
        // detaches it from the call.
        let live: () -> Bool = { settings.echoCancellationEnabled }
        let queue = PipelineQueue(
            logDir: FileManager.default.temporaryDirectory, echoCancellationEnabled: live,
        )
        XCTAssertFalse(queue.echoCancellationEnabled)

        settings.echoCancellationEnabled = true

        XCTAssertTrue(
            queue.echoCancellationEnabled,
            "turning it on must not wait for watching to be restarted",
        )
    }
}
