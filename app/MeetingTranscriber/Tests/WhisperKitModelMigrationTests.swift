@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// Issue #640: models move out of `Documents/huggingface`, and an existing copy
/// there is moved rather than downloaded again. Everything here runs on temp
/// folders; the production roots are only checked for where they point.
final class WhisperKitModelMigrationTests: XCTestCase {
    private let variant = "openai_whisper-large-v3-v20240930_turbo"

    /// A `FileManager` whose move always fails, standing in for a cross-volume or
    /// permission problem.
    private final class FailingMoveFileManager: FileManager, @unchecked Sendable {
        override func moveItem(at _: URL, to _: URL) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// A `FileManager` that loses a race: by the time it moves, another process
    /// has already moved the same model, so the move itself fails.
    private final class LosingRaceFileManager: FileManager, @unchecked Sendable {
        override func moveItem(at source: URL, to destination: URL) throws {
            try super.moveItem(at: source, to: destination)
            throw CocoaError(.fileWriteFileExists)
        }
    }

    /// A `FileManager` whose copy is interrupted halfway: it writes part of the
    /// destination and then fails.
    private final class InterruptedCopyFileManager: FileManager, @unchecked Sendable {
        override func copyItem(at _: URL, to destination: URL) throws {
            try createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("{\"trunc".utf8).write(to: destination.appendingPathComponent("tokenizer.json"))
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private func writeFile(_ url: URL, _ content: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func writeModel(in repoRoot: URL, omitting omitted: String? = nil) throws {
        for relative in WhisperKitLocalSnapshot.requiredPaths() where relative != omitted {
            try writeFile(repoRoot.appendingPathComponent(variant).appendingPathComponent(relative))
        }
    }

    private func roots() throws -> (legacy: URL, current: URL) {
        let temp = try makeTempDirectory(prefix: "wk-migration")
        return (
            temp.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml"),
            temp.appendingPathComponent("AppSupport/huggingface/models/argmaxinc/whisperkit-coreml"),
        )
    }

    // MARK: - Layout

    /// The legacy root is spelled out by hand; it must still be the layout the
    /// library writes, or no old copy is ever found.
    func testLegacyRepoRootMatchesTheLibraryLayout() {
        let base = URL(fileURLWithPath: "/tmp/old/huggingface", isDirectory: true)
        XCTAssertEqual(
            WhisperKitModelMigration.legacyRepoRoot(for: WhisperKitLocalSnapshot.repoID, base: base).standardizedFileURL.path,
            HubApiWrapper(downloadBase: base)
                .localRepoLocation(HubApiWrapper.Repo(id: WhisperKitLocalSnapshot.repoID)).standardizedFileURL.path,
        )
    }

    // MARK: - Moving

    func testCompleteLegacyModelIsMovedAndThenLocated() throws {
        let (legacy, current) = try roots()
        try writeModel(in: legacy)

        XCTAssertEqual(WhisperKitModelMigration.migrate(variant: variant, from: legacy, to: current), .moved)

        XCTAssertNotNil(WhisperKitLocalSnapshot.locate(variant: variant, in: current))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(variant).path))
    }

    func testPartialLegacyModelIsLeftWhereItIs() throws {
        let (legacy, current) = try roots()
        try writeModel(in: legacy, omitting: "TextDecoder.mlmodelc/weights/weight.bin")

        XCTAssertEqual(WhisperKitModelMigration.migrate(variant: variant, from: legacy, to: current), .nothingToMove)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(variant).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent(variant).path))
    }

    func testExistingModelAtTheNewLocationLeavesTheOldOneAlone() throws {
        let (legacy, current) = try roots()
        try writeModel(in: legacy)
        try writeModel(in: current)

        XCTAssertEqual(WhisperKitModelMigration.migrate(variant: variant, from: legacy, to: current), .keptCurrent)

        XCTAssertNotNil(WhisperKitLocalSnapshot.locate(variant: variant, in: legacy))
        XCTAssertNotNil(WhisperKitLocalSnapshot.locate(variant: variant, in: current))
    }

    /// A failed move must leave the old copy intact and the new location empty, so
    /// the locator reports nothing and the engine downloads as on a fresh install.
    func testFailedMoveFallsBackToDownloading() throws {
        let (legacy, current) = try roots()
        try writeModel(in: legacy)

        let outcome = WhisperKitModelMigration.migrate(
            variant: variant,
            from: legacy,
            to: current,
            fileManager: FailingMoveFileManager(),
        )

        guard case .failed = outcome else {
            XCTFail("expected a failure, got \(outcome)")
            return
        }
        XCTAssertNotNil(WhisperKitLocalSnapshot.locate(variant: variant, in: legacy))
        XCTAssertNil(WhisperKitLocalSnapshot.locate(variant: variant, in: current))
    }

    /// Losing a race to another process is not a failure: the model is in place.
    func testMoveThatLostARaceReportsTheModelAsPresent() throws {
        let (legacy, current) = try roots()
        try writeModel(in: legacy)

        let outcome = WhisperKitModelMigration.migrate(
            variant: variant,
            from: legacy,
            to: current,
            fileManager: LosingRaceFileManager(),
        )

        XCTAssertEqual(outcome, .keptCurrent)
        XCTAssertNotNil(WhisperKitLocalSnapshot.locate(variant: variant, in: current))
    }

    /// An iCloud placeholder anywhere in the folder, even in a file the locator
    /// does not require, keeps the copy where iCloud can still fetch it.
    func testFolderWithAnEvictedPlaceholderIsNotMoved() throws {
        let (legacy, current) = try roots()
        try writeModel(in: legacy)
        let config = legacy.appendingPathComponent(variant).appendingPathComponent("config.json")
        try writeFile(config)

        let outcome = WhisperKitModelMigration.migrate(variant: variant, from: legacy, to: current) { file in
            file.lastPathComponent == "config.json"
        }

        XCTAssertEqual(outcome, .nothingToMove)
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent(variant).path))
    }

    /// The Hub downloader's per-file metadata moves with the variant, so a later
    /// download at the new base trusts the files instead of fetching them again,
    /// and no remnant of a moved variant stays in Documents. Another variant's
    /// metadata stays with that variant.
    func testDownloadMetadataMovesWithTheVariant() throws {
        let (legacy, current) = try roots()
        try writeModel(in: legacy)
        let metadata = WhisperKitModelMigration.downloadMetadataFolder(variant: variant, in: legacy)
            .appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin.metadata")
        let otherMetadata = WhisperKitModelMigration.downloadMetadataFolder(variant: "openai_whisper-small", in: legacy)
            .appendingPathComponent("config.json.metadata")
        try writeFile(metadata, "hash\netag")
        try writeFile(otherMetadata)

        XCTAssertEqual(WhisperKitModelMigration.migrate(variant: variant, from: legacy, to: current), .moved)

        let moved = WhisperKitModelMigration.downloadMetadataFolder(variant: variant, in: current)
            .appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin.metadata")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherMetadata.path))
    }

    /// The metadata folder is where the library's downloader puts it.
    func testDownloadMetadataFolderMatchesTheHubLayout() {
        let root = URL(fileURLWithPath: "/tmp/new/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        XCTAssertEqual(
            WhisperKitModelMigration.downloadMetadataFolder(variant: variant, in: root).path,
            root.path + "/.cache/huggingface/download/" + variant,
        )
    }

    func testNothingAtTheLegacyLocationIsANoOp() throws {
        let (legacy, current) = try roots()

        XCTAssertEqual(WhisperKitModelMigration.migrate(variant: variant, from: legacy, to: current), .nothingToMove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    /// Only the variant being loaded moves; a neighbour another tool may use stays.
    func testOnlyTheRequestedVariantMoves() throws {
        let (legacy, current) = try roots()
        try writeModel(in: legacy)
        let neighbour = legacy.appendingPathComponent("openai_whisper-small/keep.txt")
        try writeFile(neighbour)

        XCTAssertEqual(WhisperKitModelMigration.migrate(variant: variant, from: legacy, to: current), .moved)

        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
    }

    // MARK: - Tokenizers

    func testTokenizersAreCopiedUnlessAlreadyPresent() throws {
        let temp = try makeTempDirectory(prefix: "wk-tokenizers")
        let legacy = temp.appendingPathComponent("old/models/openai")
        let current = temp.appendingPathComponent("new/models/openai")
        for (root, name, content) in [
            (legacy, "whisper-large-v3", "old"),
            (legacy, "whisper-small", "old"),
            (legacy, "unrelated", "old"),
            (current, "whisper-small", "new"),
        ] {
            try writeFile(root.appendingPathComponent(name).appendingPathComponent("tokenizer.json"), content)
        }

        WhisperKitModelMigration.copyTokenizers(from: legacy, to: current)

        func content(_ root: URL, _ name: String) -> String? {
            (try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent("tokenizer.json")))
                .flatMap { String(bytes: $0, encoding: .utf8) }
        }
        XCTAssertEqual(content(current, "whisper-large-v3"), "old", "a missing tokenizer is copied over")
        XCTAssertEqual(content(legacy, "whisper-large-v3"), "old", "and stays for other tools")
        XCTAssertEqual(content(current, "whisper-small"), "new", "an existing tokenizer is not replaced")
        XCTAssertEqual(content(legacy, "whisper-small"), "old")
        XCTAssertNil(content(current, "unrelated"), "only whisper tokenizers are copied")
    }

    /// An interrupted copy must not leave a tokenizer at the final path, because a
    /// present tokenizer is never copied again: the next run would keep the broken
    /// one forever. Nor may it leave its staging folder behind.
    func testInterruptedTokenizerCopyLeavesNothingBehind() throws {
        let temp = try makeTempDirectory(prefix: "wk-tokenizers")
        let legacy = temp.appendingPathComponent("old/models/openai")
        let current = temp.appendingPathComponent("new/models/openai")
        try writeFile(legacy.appendingPathComponent("whisper-small/tokenizer.json"), "{}")

        WhisperKitModelMigration.copyTokenizers(from: legacy, to: current, fileManager: InterruptedCopyFileManager())

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: current.path), [])

        WhisperKitModelMigration.copyTokenizers(from: legacy, to: current)
        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("whisper-small/tokenizer.json"), encoding: .utf8),
            "{}",
            "the next run copies it whole",
        )
    }

    func testEvictedTokenizerIsNotCopied() throws {
        let temp = try makeTempDirectory(prefix: "wk-tokenizers")
        let legacy = temp.appendingPathComponent("old/models/openai")
        let current = temp.appendingPathComponent("new/models/openai")
        try writeFile(legacy.appendingPathComponent("whisper-small/tokenizer.json"))

        WhisperKitModelMigration.copyTokenizers(from: legacy, to: current) { _ in true }

        XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("whisper-small").path))
    }
}
