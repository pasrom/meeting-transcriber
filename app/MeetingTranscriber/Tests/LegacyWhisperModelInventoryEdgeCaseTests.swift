@testable import MeetingTranscriber
import XCTest

/// Edge cases of the leftover-model inventory: in-flight changes, symlinked or
/// unreadable folders, the migration lock and the shared move decision. The
/// tree is `LegacyWhisperModelTree`.
final class LegacyWhisperModelInventoryEdgeCaseTests: XCTestCase {
    private typealias Tree = LegacyWhisperModelTree
    private typealias FakeTrash = LegacyWhisperFakeTrash

    private let small = Tree.small
    private let base = Tree.base
    private let unknownVariant = Tree.unknownVariant

    private func makeTree() throws -> Tree {
        try Tree.make(in: makeTempDirectory(prefix: "legacy-wk-edge"))
    }

    private func write(_ url: URL, bytes: Int) throws {
        try Tree.write(url, bytes: bytes)
    }

    private func scan(_ tree: Tree) throws -> [LegacyWhisperModel] {
        try tree.scan()
    }

    private func moveToTrash(_ models: [LegacyWhisperModel], in tree: Tree, trash: FakeTrash) -> [LegacyWhisperModelInventory.Failure] {
        tree.moveToTrash(models, trash: trash)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func assertEverythingElseIsUntouched(_ tree: Tree, file: StaticString = #filePath, line: UInt = #line) {
        tree.assertEverythingElseIsUntouched(file: file, line: line)
    }

    /// A trash error is described without the path Foundation would put in it.
    func testTrashErrorsAreDescribedWithoutAPath() throws {
        let tree = try makeTree()
        let base = base

        let failures = LegacyWhisperModelInventory.moveToTrash(
            [LegacyWhisperModel(variant: base, bytes: 0), LegacyWhisperModel(variant: small, bytes: 0)],
            scope: tree.scope(),
            isEvicted: { _ in false },
            trash: { url in
                if url.path.contains("/.cache/") { throw CocoaError(.fileReadNoSuchFile) }
                if url.lastPathComponent == base { throw NSError(domain: "Test", code: 7) }
            },
        )

        XCTAssertEqual(failures.map(\.reason), ["Error Test 7.", "It no longer exists."])
    }

    func testRowLabelNamesTheVariantAndItsSize() {
        let size = ByteCountFormatter.string(fromByteCount: 480_000_000, countStyle: .file)

        XCTAssertEqual(LegacyWhisperModelInventory.rowLabel(.init(variant: small, bytes: 480_000_000)), "\(small) (\(size))")
    }

    /// The new location comes from the engine's own lookup unless a test says otherwise.
    func testTheCurrentRepositoryIsTheEnginesLookup() {
        let scope = LegacyWhisperModelInventory.Scope(legacyBase: URL(fileURLWithPath: "/tmp/old"), knownVariants: [])

        XCTAssertEqual(scope.currentRepoRoot, WhisperKitLocalSnapshot.repoRoot(for: WhisperKitLocalSnapshot.repoID))
    }

    /// APFS is usually case-insensitive: a picked folder spelled in another case
    /// is the same folder and must protect the variant.
    func testAPickedFolderSpelledInAnotherCaseStillProtects() throws {
        let tree = try makeTree()
        let caseSensitive = try tree.temp.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        try XCTSkipIf(caseSensitive, "the temp volume is case-sensitive")
        let picked = tree.repoRoot.deletingLastPathComponent().appendingPathComponent("WhisperKit-CoreML/OPENAI_WHISPER-SMALL")

        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(picked: [picked])).map(\.variant), [base])
    }

    /// The same folder reached through the data volume's firmlink: no symlink
    /// to resolve, so only file identity says it is the variant.
    func testAPickedFolderReachedThroughAFirmlinkStillProtects() throws {
        let tree = try makeTree()
        // `resolvingSymlinksInPath` drops the `/private` of a temp path; the
        // data volume keeps it.
        let resolved = tree.repoRoot.appendingPathComponent(small).resolvingSymlinksInPath().path
        let onDataVolume = resolved.hasPrefix("/var/") ? "/private" + resolved : resolved
        let picked = URL(fileURLWithPath: "/System/Volumes/Data" + onDataVolume, isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: picked.path), "no data-volume firmlink here")

        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(picked: [picked])).map(\.variant), [base])
    }

    /// A variant folder already gone (moved, deleted by hand) leaves its download
    /// metadata behind; with nothing left to list it by, removal still trashes it.
    func testMetadataOfAVanishedVariantIsTrashed() throws {
        let tree = try makeTree()
        try FileManager.default.removeItem(at: tree.repoRoot.appendingPathComponent(small))
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = moveToTrash([LegacyWhisperModel(variant: small, bytes: 0)], in: tree, trash: trash)

        XCTAssertEqual(failures, [])
        XCTAssertEqual(trash.trashed, [tree.metadata(small).path])
        assertEverythingElseIsUntouched(tree)
    }

    /// The trash reporting the folder gone in the meantime still lets the metadata go.
    func testMetadataGoesWhenTheVariantVanishesDuringTheMove() throws {
        let tree = try makeTree()
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = LegacyWhisperModelInventory.moveToTrash(
            [LegacyWhisperModel(variant: small, bytes: 0)],
            scope: tree.scope(),
            isEvicted: { _ in false },
            trash: { url in
                if url.lastPathComponent == self.small, !url.path.contains("/.cache/") {
                    throw CocoaError(.fileNoSuchFile)
                }
                try trash(url)
            },
        )

        XCTAssertEqual(failures, [])
        XCTAssertEqual(trash.trashed, [tree.metadata(small).path])
    }

    /// Orphaned metadata is only ever taken for a variant this app knows.
    func testOrphanedMetadataOfAnUnknownVariantStays() throws {
        let tree = try makeTree()
        let foreign = tree.metadata("someone-elses-variant")
        try write(foreign.appendingPathComponent("config.json.metadata"), bytes: 3)
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = moveToTrash([LegacyWhisperModel(variant: "someone-elses-variant", bytes: 0)], in: tree, trash: trash)

        XCTAssertEqual(failures.map(\.item), ["someone-elses-variant"])
        XCTAssertEqual(trash.trashed, [])
        XCTAssertTrue(exists(foreign))
    }

    /// Each folder goes under its variant's migration lock, so a load cannot
    /// move it half-way through; a load of another variant is not held up.
    func testTrashingHoldsThatVariantsMigrationLockOnly() throws {
        let tree = try makeTree()
        let small = small
        let base = base
        var sameVariantGotIn = true
        var otherVariantGotIn = false
        var checked = false

        _ = LegacyWhisperModelInventory.moveToTrash(
            [LegacyWhisperModel(variant: small, bytes: 0)],
            scope: tree.scope(),
            isEvicted: { _ in false },
            trash: { _ in
                guard !checked else { return }
                checked = true
                let same = DispatchSemaphore(value: 0)
                let other = DispatchSemaphore(value: 0)
                // Spelled in another case: the lock follows the volume, not the spelling.
                DispatchQueue.global().async { WhisperKitModelMigration.withLegacyFolderLock(variant: small.uppercased()) { _ = same.signal() } }
                DispatchQueue.global().async { WhisperKitModelMigration.withLegacyFolderLock(variant: base) { _ = other.signal() } }
                otherVariantGotIn = other.wait(timeout: .now() + 5) == .success
                sameVariantGotIn = same.wait(timeout: .now() + 0.3) == .success
            },
        )

        XCTAssertTrue(checked)
        XCTAssertFalse(sameVariantGotIn)
        XCTAssertTrue(otherVariantGotIn)
    }

    /// With the variant folder gone, partial files in its metadata are another
    /// tool's download in progress; they stay.
    func testOrphanedMetadataWithADownloadInProgressStays() throws {
        let tree = try makeTree()
        try FileManager.default.removeItem(at: tree.repoRoot.appendingPathComponent(small))
        try write(tree.metadata(small).appendingPathComponent("config.json.abc123.incomplete"), bytes: 3)
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = moveToTrash([LegacyWhisperModel(variant: small, bytes: 0)], in: tree, trash: trash)

        XCTAssertEqual(failures, [.init(item: "\(small) download metadata", reason: "A download is in progress there.")])
        XCTAssertEqual(trash.trashed, [])
    }

    /// The selected variant's name may be spelled in another case than its
    /// folder (a typed custom variant); the volume, and the migration, do not care.
    func testTheSelectedVariantIsMatchedIgnoringCase() throws {
        let tree = try makeTree()
        for relative in WhisperKitLocalSnapshot.requiredPaths() {
            try write(tree.repoRoot.appendingPathComponent(base).appendingPathComponent(relative), bytes: 1)
        }

        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(selected: base.uppercased())).map(\.variant), [small])
    }

    /// The copy in use reached through a symlink at the new location must never
    /// look like a leftover, whether the variant or the whole repository is linked.
    func testACurrentCopyThatIsASymlinkIntoTheOldFolderIsNeverTrashed() throws {
        let tree = try makeTree()
        let currentSmall = tree.currentRepoRoot.appendingPathComponent(small)
        try FileManager.default.removeItem(at: currentSmall)
        try FileManager.default.createSymbolicLink(at: currentSmall, withDestinationURL: tree.repoRoot.appendingPathComponent(small))
        let trash = FakeTrash(folder: tree.trashFolder)

        XCTAssertEqual(try scan(tree).map(\.variant), [base])
        let failures = moveToTrash([LegacyWhisperModel(variant: small, bytes: 0)], in: tree, trash: trash)

        XCTAssertEqual(failures.map(\.item), [small])
        XCTAssertEqual(trash.trashed, [])
    }

    func testACurrentRepositoryThatIsASymlinkIntoTheOldOneListsAndTrashesNothing() throws {
        let tree = try makeTree()
        try FileManager.default.removeItem(at: tree.currentRepoRoot)
        try FileManager.default.createSymbolicLink(at: tree.currentRepoRoot, withDestinationURL: tree.repoRoot)
        let trash = FakeTrash(folder: tree.trashFolder)

        XCTAssertEqual(try scan(tree), [])
        let failures = moveToTrash([LegacyWhisperModel(variant: base, bytes: 0)], in: tree, trash: trash)

        XCTAssertEqual(failures, [.init(item: base, reason: "It is in the folder the app uses now.")])
        XCTAssertEqual(trash.trashed, [])
    }

    /// Only "no such file" means a variant is gone. A folder that cannot be
    /// looked at (no permission) is reported, and its metadata stays.
    func testAFolderThatCannotBeReadIsReportedNotTakenForGone() throws {
        let tree = try makeTree()
        let trash = FakeTrash(folder: tree.trashFolder)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tree.repoRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.repoRoot.path) }

        let failures = moveToTrash([LegacyWhisperModel(variant: small, bytes: 0)], in: tree, trash: trash)

        XCTAssertEqual(failures, [.init(item: small, reason: "Permission denied.")])
        XCTAssertEqual(trash.trashed, [])
        XCTAssertThrowsError(try scan(tree))
    }

    /// The migration never waits long behind a trash of the same variant: it
    /// gives up and the load goes on as with nothing to move.
    func testTheMigrationSkipsInsteadOfWaitingBehindATrash() {
        let small = small
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            WhisperKitModelMigration.withLegacyFolderLock(variant: small) {
                held.signal()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        XCTAssertEqual(held.wait(timeout: .now() + 5), .success)
        var ran = false
        let started = Date()

        let completed = WhisperKitModelMigration.withLegacyFolderLockOrSkip(variant: small, wait: 0.2) { ran = true }

        let waited = Date().timeIntervalSince(started)
        release.signal()
        XCTAssertFalse(completed)
        XCTAssertFalse(ran)
        XCTAssertLessThan(waited, 2)
        XCTAssertTrue(WhisperKitModelMigration.withLegacyFolderLockOrSkip(variant: small, wait: 5) { ran = true })
        XCTAssertTrue(ran)
    }

    /// One decision for the migration and for what the Trash may take.
    func testTheMoveDecisionIsTheMigrationsOwn() throws {
        let tree = try makeTree()
        for relative in WhisperKitLocalSnapshot.requiredPaths() {
            try write(tree.repoRoot.appendingPathComponent(base).appendingPathComponent(relative), bytes: 1)
        }
        let decide = { (variant: String) in
            WhisperKitModelMigration.decision(variant: variant, from: tree.repoRoot, to: tree.currentRepoRoot) { _ in false }
        }

        XCTAssertEqual(decide(small), .keptCurrent)
        XCTAssertEqual(decide(base), .willMove)
        XCTAssertEqual(decide(unknownVariant), .nothingToMove)
        XCTAssertEqual(WhisperKitModelMigration.migrate(variant: base, from: tree.repoRoot, to: tree.currentRepoRoot) { _ in false }, .moved)
    }
}
