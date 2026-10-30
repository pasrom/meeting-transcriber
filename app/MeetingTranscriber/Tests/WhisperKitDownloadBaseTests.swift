@testable import MeetingTranscriber
import XCTest

/// Issue #640: WhisperKit models are kept out of `Documents`, which iCloud
/// "Desktop & Documents" syncs, and every WhisperKit call gets the same base.
final class WhisperKitDownloadBaseTests: XCTestCase {
    /// The point of issue #640: the download base is not in Documents, and the
    /// locator derives its root from that same base.
    func testDownloadBaseIsOutsideDocumentsAndSharedWithTheLocator() throws {
        let base = WhisperKitLocalSnapshot.downloadBaseLocation.standardizedFileURL.path
        XCTAssertTrue(base.hasPrefix(AppPaths.dataDir.standardizedFileURL.path))
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        XCTAssertFalse(base.hasPrefix(documents.standardizedFileURL.path))
        XCTAssertTrue(
            WhisperKitLocalSnapshot.defaultRepoRoot.standardizedFileURL.path
                .hasPrefix(base + "/models/argmaxinc/whisperkit-coreml"),
        )
    }

    /// The pipe must get the same base, or WhisperKit looks for the tokenizer in
    /// Documents and downloads it there.
    func testPipeConfigCarriesTheDownloadBase() {
        let base = URL(fileURLWithPath: "/tmp/wk-base", isDirectory: true)
        let config = WhisperKitModelSource.pipeConfig(
            variant: "openai_whisper-small",
            folder: URL(fileURLWithPath: "/tmp/m"),
            downloadBase: base,
        )
        XCTAssertEqual(config.downloadBase, base)
        XCTAssertNil(config.tokenizerFolder, "so WhisperKit takes the tokenizer cache from downloadBase")
        XCTAssertEqual(config.modelFolder, "/tmp/m")
    }

    func testPrepareDownloadBaseCreatesTheFolderExcludedFromBackup() throws {
        let base = try makeTempDirectory(prefix: "wk-base").appendingPathComponent("huggingface")

        WhisperKitLocalSnapshot.prepareDownloadBase(base)

        let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isExcludedFromBackupKey])
        XCTAssertTrue(values.isDirectory ?? false)
        XCTAssertTrue(values.isExcludedFromBackup ?? false)
    }
}
