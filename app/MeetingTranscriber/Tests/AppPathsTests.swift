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
}
