@testable import MeetingTranscriber
import XCTest

/// Leftover WhisperKit models in `Documents/huggingface` (issue #640): what is
/// listed, and that removal trashes a variant and its own metadata and nothing
/// else. Everything runs on a temp tree with an injected trash that moves into a
/// temp folder, never on the real `Documents` or the real Trash.
final class LegacyWhisperModelInventoryTests: XCTestCase {
    private typealias Tree = LegacyWhisperModelTree
    private typealias FakeTrash = LegacyWhisperFakeTrash

    private let small = Tree.small
    private let base = Tree.base
    private let unknownVariant = Tree.unknownVariant

    private func makeTree() throws -> Tree {
        try Tree.make(in: makeTempDirectory(prefix: "legacy-wk"))
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

    /// What the files take on disk, which is what the scan reports.
    private func allocated(_ files: URL...) throws -> Int64 {
        try files.reduce(0) { total, file in
            try total + Int64(XCTUnwrap(file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize))
        }
    }

    // MARK: - Listing

    /// Only the two real, visible, known variant folders; an evicted file counts
    /// zero and a symlinked file is not followed.
    func testScanListsOnlyRealVariantFoldersWithTheirLocalSize() throws {
        let tree = try makeTree()
        let smallFolder = tree.repoRoot.appendingPathComponent(small)

        let expected = try [
            LegacyWhisperModel(variant: base, bytes: allocated(tree.repoRoot.appendingPathComponent("\(base)/config.json"))),
            LegacyWhisperModel(variant: small, bytes: allocated(
                smallFolder.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin"),
                smallFolder.appendingPathComponent("config.json"),
                smallFolder.appendingPathComponent(".DS_Store"),
            )),
        ]

        XCTAssertEqual(try scan(tree), expected)
    }

    /// A model folder loaded in place that points into a variant keeps it, and
    /// so does one that contains the repository folder.
    func testAVariantAPickedFolderPointsIntoIsNotListed() throws {
        let tree = try makeTree()
        let picked = tree.repoRoot.appendingPathComponent(small)
        let link = tree.temp.appendingPathComponent("MyModel")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: picked)

        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(picked: [picked])).map(\.variant), [base])
        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(picked: [link])).map(\.variant), [base])
        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(picked: [tree.huggingface])), [])
    }

    /// The selected variant, complete here and not yet at the new location, is
    /// what the next load moves over; trashing it would cost a download.
    func testTheSelectedVariantStaysWhileTheMigrationWouldStillMoveIt() throws {
        let tree = try makeTree()
        for relative in WhisperKitLocalSnapshot.requiredPaths() {
            try write(tree.repoRoot.appendingPathComponent(base).appendingPathComponent(relative), bytes: 1)
        }

        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(selected: base)).map(\.variant), [small])
        // Already at the new location (small is): a kept-current leftover.
        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(selected: small)).map(\.variant), [base, small])
    }

    func testAnIncompleteSelectedVariantIsListed() throws {
        let tree = try makeTree()

        XCTAssertEqual(try LegacyWhisperModelInventory.scan(tree.scope(selected: base)).map(\.variant), [base, small])
    }

    func testAFullyEvictedVariantIsStillListed() throws {
        let tree = try makeTree()
        try FileManager.default.removeItem(at: tree.repoRoot.appendingPathComponent("\(base)/config.json"))

        XCTAssertEqual(try scan(tree).first, LegacyWhisperModel(variant: base, bytes: 0))
    }

    func testScanOfAMissingFolderListsNothing() throws {
        let temp = try makeTempDirectory(prefix: "legacy-wk-empty")

        let scope = LegacyWhisperModelInventory.Scope(
            legacyBase: temp.appendingPathComponent("absent"),
            knownVariants: [small],
            currentBase: temp.appendingPathComponent("new"),
        )

        XCTAssertEqual(try LegacyWhisperModelInventory.scan(scope), [])
        XCTAssertFalse(LegacyWhisperModelInventory.isSyncedToICloud(temp))
    }

    /// A legacy folder that leads into the folder in use (a symlink someone made)
    /// must list nothing, or "leftovers" would be the models the app loads.
    func testNothingIsListedOrTrashedWhenTheOldFolderLeadsIntoTheNewOne() throws {
        let tree = try makeTree()
        let linkedBase = tree.temp.appendingPathComponent("LinkedDocuments", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedBase, withDestinationURL: tree.currentBase)
        let scope = LegacyWhisperModelInventory.Scope(
            legacyBase: linkedBase,
            knownVariants: [small],
            currentBase: tree.currentBase,
            currentRepoRoot: tree.currentRepoRoot,
        )
        let trash = FakeTrash(folder: tree.trashFolder)

        XCTAssertEqual(try LegacyWhisperModelInventory.scan(scope), [])
        let failures = LegacyWhisperModelInventory.moveToTrash(
            [LegacyWhisperModel(variant: small, bytes: 3)],
            scope: scope,
            trash: trash.callAsFunction,
        )

        XCTAssertEqual(failures.map(\.item), [small])
        XCTAssertEqual(trash.trashed, [])
        assertEverythingElseIsUntouched(tree)
    }

    // MARK: - Removal

    func testRemovalTrashesEachVariantWithItsMetadataAndNothingElse() throws {
        let tree = try makeTree()
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = try moveToTrash(scan(tree), in: tree, trash: trash)

        XCTAssertEqual(failures, [])
        XCTAssertEqual(trash.trashed, [
            tree.repoRoot.appendingPathComponent(base).path,
            tree.metadata(base).path,
            tree.repoRoot.appendingPathComponent(small).path,
            tree.metadata(small).path,
        ])
        XCTAssertEqual(try scan(tree), [])
        assertEverythingElseIsUntouched(tree)
    }

    func testAVariantWithoutMetadataIsTrashedAlone() throws {
        let tree = try makeTree()
        try FileManager.default.removeItem(at: tree.metadata(small))
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = moveToTrash([LegacyWhisperModel(variant: small, bytes: 0)], in: tree, trash: trash)

        XCTAssertEqual(failures, [])
        XCTAssertEqual(trash.trashed, [tree.repoRoot.appendingPathComponent(small).path])
    }

    /// A `.cache` that is a symlink leads out of the repository folder; whatever
    /// it points at is not this variant's metadata.
    func testMetadataBehindASymlinkedCacheIsLeftAlone() throws {
        let tree = try makeTree()
        let cache = tree.repoRoot.appendingPathComponent(".cache")
        let foreign = tree.temp.appendingPathComponent("ForeignCache", isDirectory: true)
        try FileManager.default.moveItem(at: cache, to: foreign)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: foreign)
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = moveToTrash([LegacyWhisperModel(variant: small, bytes: 0)], in: tree, trash: trash)

        XCTAssertEqual(failures, [])
        XCTAssertEqual(trash.trashed, [tree.repoRoot.appendingPathComponent(small).path])
        XCTAssertTrue(exists(foreign.appendingPathComponent("huggingface/download/\(small)/config.json.metadata")))
    }

    /// A failed variant is reported, keeps its metadata, and does not stop the next.
    func testATrashFailureIsReportedAndTheRestStillGoes() throws {
        let tree = try makeTree()
        let trash = FakeTrash(folder: tree.trashFolder)
        trash.failing = [base]

        let failures = try moveToTrash(scan(tree), in: tree, trash: trash)

        XCTAssertEqual(failures, [.init(item: base, reason: "Permission denied.")])
        XCTAssertEqual(trash.trashed, [tree.repoRoot.appendingPathComponent(small).path, tree.metadata(small).path])
        XCTAssertTrue(exists(tree.metadata(base)))
        XCTAssertEqual(try scan(tree).map(\.variant), [base])
    }

    func testAMetadataTrashFailureIsReported() throws {
        let tree = try makeTree()
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = LegacyWhisperModelInventory.moveToTrash(
            [LegacyWhisperModel(variant: small, bytes: 0)],
            scope: tree.scope(),
            isEvicted: { _ in false },
            trash: { url in
                if url.path.contains("/.cache/") { throw CocoaError(.fileWriteNoPermission) }
                try trash(url)
            },
        )

        XCTAssertEqual(failures.map(\.item), ["\(small) download metadata"])
        XCTAssertEqual(trash.trashed, [tree.repoRoot.appendingPathComponent(small).path])
        XCTAssertTrue(exists(tree.metadata(small)))
    }

    /// The disk can change between the scan and the click: a variant that became
    /// a symlink is reported and not followed; one that vanished leaves only its
    /// metadata to take.
    func testAVariantThatIsNoLongerAFolderIsReportedNotTrashed() throws {
        let tree = try makeTree()
        let models = try scan(tree)
        let smallFolder = tree.repoRoot.appendingPathComponent(small)
        try FileManager.default.moveItem(at: smallFolder, to: tree.temp.appendingPathComponent("moved-small"))
        try FileManager.default.createSymbolicLink(at: smallFolder, withDestinationURL: tree.temp.appendingPathComponent("moved-small"))
        try FileManager.default.removeItem(at: tree.repoRoot.appendingPathComponent(base))
        let trash = FakeTrash(folder: tree.trashFolder)

        let failures = moveToTrash(models, in: tree, trash: trash)

        XCTAssertEqual(failures.map(\.item), [small])
        XCTAssertEqual(trash.trashed, [tree.metadata(base).path])
        XCTAssertTrue(exists(tree.metadata(small)))
        XCTAssertTrue(exists(tree.temp.appendingPathComponent("moved-small/config.json")))
    }

    /// Names that are not a single visible component never reach the trash.
    func testNamesOutsideTheRepositoryFolderAreRefused() throws {
        let tree = try makeTree()
        let trash = FakeTrash(folder: tree.trashFolder)

        let names = ["", ".cache", "../openai", "openai_whisper-linked", "notes.txt", unknownVariant]

        let failures = moveToTrash(names.map { LegacyWhisperModel(variant: $0, bytes: 0) }, in: tree, trash: trash)

        XCTAssertEqual(failures.count, 6)
        XCTAssertEqual(trash.trashed, [])
        assertEverythingElseIsUntouched(tree)
    }

    // MARK: - Text and wiring

    func testSummaryCountsAndSizesTheModels() {
        let models = [LegacyWhisperModel(variant: small, bytes: 1_500_000_000), LegacyWhisperModel(variant: base, bytes: 400_000_000)]
        let size = ByteCountFormatter.string(fromByteCount: 1_900_000_000, countStyle: .file)

        XCTAssertEqual(
            LegacyWhisperModelInventory.summary(models, syncedToICloud: true),
            "Old models in Documents: 2 (\(size)), synced to iCloud",
        )
        XCTAssertEqual(LegacyWhisperModelInventory.summary(models, syncedToICloud: false), "Old models in Documents: 2 (\(size))")
    }

    func testConfirmationNamesWhatGoes() {
        let models = [LegacyWhisperModel(variant: small, bytes: 10), LegacyWhisperModel(variant: base, bytes: 0)]
        let synced = LegacyWhisperModelInventory.confirmationMessage(models, syncedToICloud: true)
        let local = LegacyWhisperModelInventory.confirmationMessage(models, syncedToICloud: false)

        XCTAssertTrue(synced.hasPrefix("\(small), \(base) ("), synced)
        XCTAssertTrue(synced.contains("moved to the Trash"), synced)
        XCTAssertTrue(synced.contains("removed from iCloud Drive"), synced)
        XCTAssertTrue(synced.contains("Other apps that use WhisperKit can share this folder"), synced)
        XCTAssertTrue(LegacyWhisperModelInventory.sharedFolderNote.hasPrefix("Other apps that use WhisperKit can share this folder."))
        XCTAssertFalse(local.contains("iCloud"), local)
    }

    func testFailureMessageListsEachItem() {
        XCTAssertNil(LegacyWhisperModelInventory.failureMessage([]))
        XCTAssertEqual(
            LegacyWhisperModelInventory.failureMessage([.init(item: "a", reason: "r1."), .init(item: "b", reason: "r2.")]),
            "Could not move a to the Trash: r1.\nCould not move b to the Trash: r2.",
        )
    }
}
