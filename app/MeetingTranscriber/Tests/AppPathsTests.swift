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

    /// Every constant that names a directory has to *be* a directory URL, and
    /// not because it is tidier.
    ///
    /// `URL.appendingPathComponent(_:)` without the `isDirectory:` argument asks
    /// the filesystem whether the component it just appended is a directory, and
    /// marks the URL (and so its trailing slash) from the answer. These are
    /// `static let`s, so that question is asked once per process, at whatever
    /// moment the first access happens, and on a machine where the directory
    /// does not exist yet the answer is "no". The URL then compares unequal to
    /// the same directory reached any other way: `deletingLastPathComponent()`
    /// on a child always yields the slashed form. That is a constant whose value
    /// depends on disk state and on evaluation order, and it made
    /// `testLivenessMarkerIsNamedPerBundleInTheDataDirectory` pass on a
    /// developer machine and fail on a fresh CI runner, in one variant of one
    /// run, with no code change between the two.
    ///
    /// The file constants are left alone: a missing file probes as a file, which
    /// is what they should be, so they carry no such swing.
    func testTheDirectoryConstantsAreDirectoryURLs() {
        let directories: [(String, URL)] = [
            ("dataDir", AppPaths.dataDir),
            ("ipcDir", AppPaths.ipcDir),
            ("recordingsDir", AppPaths.recordingsDir),
            ("protocolsDir", AppPaths.protocolsDir),
            ("downloadsProtocolsDir", AppPaths.downloadsProtocolsDir),
        ]
        for (name, url) in directories {
            XCTAssertTrue(url.hasDirectoryPath, "\(name) must not depend on whether it exists yet")
        }
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
