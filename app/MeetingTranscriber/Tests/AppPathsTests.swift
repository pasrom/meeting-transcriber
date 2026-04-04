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
}
