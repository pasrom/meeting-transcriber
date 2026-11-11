@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class TranscriptionSettingsIdleModelTests: XCTestCase {
    func testIdleUnloadToggleWritesBackToSettings() throws {
        let settings = try makeIsolatedSettings()
        let toggle = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.unloadModelsWhenIdleToggle)
            .find(ViewType.Toggle.self)

        try toggle.tap()

        XCTAssertFalse(settings.unloadModelsWhenIdle)
    }

    func testUnloadedStatusSaysLoadsWhenNeededOnlyWithIdleUnloadingOn() throws {
        let settings = try makeIsolatedSettings()
        XCTAssertNoThrow(try makeView(settings).inspect().find(text: "Loads when needed"))
        settings.unloadModelsWhenIdle = false
        XCTAssertThrowsError(try makeView(settings).inspect().find(text: "Loads when needed"))
    }

    private func makeView(_ settings: AppSettings) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine(),
        )
    }
}
