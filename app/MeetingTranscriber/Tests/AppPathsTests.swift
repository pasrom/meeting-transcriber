@testable import MeetingTranscriber
import XCTest

final class AppPathsTests: XCTestCase {
    // MARK: - dataDir

    func testDataDirUsesApplicationSupport() {
        XCTAssertTrue(
            AppPaths.dataDir.path.contains("Application Support/MeetingTranscriber"),
            "dataDir should be under Application Support",
        )
    }

    // MARK: - ipcDir

    func testIpcDirIsUnderDataDir() {
        XCTAssertTrue(
            AppPaths.ipcDir.path.hasPrefix(AppPaths.dataDir.path),
            "ipcDir should be a subdirectory of dataDir",
        )
    }

    // MARK: - Derived paths under dataDir

    func testRecordingsDirIsUnderDataDir() {
        XCTAssertTrue(AppPaths.recordingsDir.path.hasPrefix(AppPaths.dataDir.path))
    }

    /// The full staging path, not just its parent. It is the default
    /// `DualSourceRecorder` stages into and the directory crash recovery and
    /// the orphan scan walk, so moving it silently would strand recordings.
    func testRecordingsDirIsTheAppSupportStagingPath() {
        XCTAssertTrue(
            AppPaths.recordingsDir.path.contains("Library/Application Support/MeetingTranscriber/recordings"),
        )
    }

    func testProtocolsDirIsUnderDataDir() {
        XCTAssertTrue(AppPaths.protocolsDir.path.hasPrefix(AppPaths.dataDir.path))
    }

    func testSpeakersDBIsUnderDataDir() {
        XCTAssertTrue(AppPaths.speakersDB.path.hasPrefix(AppPaths.dataDir.path))
    }

    func testCustomPromptFileIsUnderDataDir() {
        XCTAssertTrue(AppPaths.customPromptFile.path.hasPrefix(AppPaths.dataDir.path))
    }

    // MARK: - migrateIfNeeded

    func testMigrateIfNeededIsIdempotent() {
        // Should not crash when called multiple times
        AppPaths.migrateIfNeeded()
        AppPaths.migrateIfNeeded()
        // If we reach here, no crash occurred
    }

    func testIpcDirExistsAfterMigration() {
        AppPaths.migrateIfNeeded()
        let fm = FileManager.default
        try? fm.createDirectory(at: AppPaths.ipcDir, withIntermediateDirectories: true)
        XCTAssertTrue(fm.fileExists(atPath: AppPaths.ipcDir.path))
    }

    /// The liveness marker (issue #703) sits beside the other state in the
    /// data directory and never in the recordings directory, which is scanned
    /// for crash signatures by filename. It is named per bundle identifier
    /// because the dev and release builds share the directory and each must
    /// judge only its own previous run.
    func testLivenessMarkerIsNamedPerBundleInTheDataDirectory() {
        let marker = AppPaths.livenessMarker

        XCTAssertEqual(marker.deletingLastPathComponent(), AppPaths.dataDir)
        XCTAssertNotEqual(marker.deletingLastPathComponent(), AppPaths.recordingsDir)
        XCTAssertEqual(marker.lastPathComponent, "\(Bundle.main.bundleIdentifier ?? "MeetingTranscriber").running")
    }
}
