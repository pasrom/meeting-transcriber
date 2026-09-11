@testable import AudioTapLib
import XCTest

/// The pane name is version-dependent (macOS 15 renamed "Screen Recording" to
/// "Screen & System Audio Recording") and shared by the tap-error hint, the
/// permission UI, and the channel-health notification, so it is worth pinning.
final class SystemSettingsPathsTests: XCTestCase {
    func testScreenRecordingPathUsesSequoiaPaneName() {
        XCTAssertEqual(
            SystemSettingsPaths.screenRecordingPath(sequoiaOrLater: true),
            "System Settings → Privacy & Security → Screen & System Audio Recording",
        )
    }

    func testScreenRecordingPathUsesLegacyPaneNameBeforeSequoia() {
        XCTAssertEqual(
            SystemSettingsPaths.screenRecordingPath(sequoiaOrLater: false),
            "System Settings → Privacy & Security → Screen Recording",
        )
    }

    func testScreenRecordingResolvesToAKnownPane() {
        // The OS-resolved value must match one of the two version branches.
        let resolved = SystemSettingsPaths.screenRecording
        XCTAssertTrue(
            resolved == SystemSettingsPaths.screenRecordingPath(sequoiaOrLater: true)
                || resolved == SystemSettingsPaths.screenRecordingPath(sequoiaOrLater: false),
        )
    }

    func testSoundOutputNamesThePaneThatChangesTheOutputDevice() {
        // Not version-dependent the way the recording pane is: Ventura through
        // macOS 26 all keep Output inside the Sound pane, and the app's floor is
        // macOS 14.2.
        XCTAssertEqual(SystemSettingsPaths.soundOutput, "System Settings → Sound → Output")
    }
}
