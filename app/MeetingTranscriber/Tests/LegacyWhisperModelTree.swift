@testable import MeetingTranscriber
import XCTest

/// The temp tree the leftover-model inventory tests run on: two variants (one
/// with an evicted file and a symlink to a big file outside), a symlinked folder,
/// a file, a dot folder, a folder with the hidden flag, a variant this app never
/// offered, the repository's `.cache`, the tokenizer cache, another tool's folder
/// and the new location. Never the real `Documents` or Trash.
struct LegacyWhisperModelTree {
    static let small = "openai_whisper-small"
    static let base = "openai_whisper-base"
    static let evictedFile = "weights-evicted.bin"
    /// A real variant folder this app never offered, as another WhisperKit tool
    /// sharing the repository folder would leave.
    static let unknownVariant = "distil-whisper_distil-large-v3"

    let temp: URL
    let huggingface: URL
    let repoRoot: URL
    let currentBase: URL
    let trashFolder: URL

    var currentRepoRoot: URL {
        currentBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    func metadata(_ variant: String) -> URL {
        WhisperKitModelMigration.downloadMetadataFolder(variant: variant, in: repoRoot)
    }

    /// Every entry's name is "known", so the structural checks are what keep
    /// the traps out; `unknownVariant` alone tests the allowlist.
    func scope(selected: String? = nil, picked: [URL] = []) -> LegacyWhisperModelInventory.Scope {
        .init(
            legacyBase: huggingface,
            knownVariants: [
                "openai_whisper-small", "openai_whisper-base", "openai_whisper-linked",
                "openai_whisper-flagged", ".hidden-variant", "notes.txt", ".cache",
            ],
            currentBase: currentBase,
            currentRepoRoot: currentRepoRoot,
            pickedFolders: picked,
            selectedVariant: selected,
        )
    }

    static func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    static func isEvicted(_ url: URL) -> Bool {
        url.lastPathComponent == evictedFile
    }

    func scan() throws -> [LegacyWhisperModel] {
        try LegacyWhisperModelInventory.scan(scope(), isEvicted: Self.isEvicted)
    }

    func moveToTrash(_ models: [LegacyWhisperModel], trash: LegacyWhisperFakeTrash) -> [LegacyWhisperModelInventory.Failure] {
        LegacyWhisperModelInventory.moveToTrash(models, scope: scope(), isEvicted: Self.isEvicted, trash: trash.callAsFunction)
    }

    /// Builds the tree inside `temp`, a fresh temp folder the caller cleans up.
    static func make(in temp: URL) throws -> Self {
        let huggingface = temp.appendingPathComponent("Documents/huggingface", isDirectory: true)
        let repoRoot = WhisperKitModelMigration.legacyRepoRoot(for: WhisperKitLocalSnapshot.repoID, base: huggingface)
        let tree = Self(
            temp: temp,
            huggingface: huggingface,
            repoRoot: repoRoot,
            currentBase: temp.appendingPathComponent("AppSupport/huggingface", isDirectory: true),
            trashFolder: temp.appendingPathComponent("FakeTrash", isDirectory: true),
        )
        try FileManager.default.createDirectory(at: tree.trashFolder, withIntermediateDirectories: true)

        try write(repoRoot.appendingPathComponent("\(small)/AudioEncoder.mlmodelc/weights/weight.bin"), bytes: 1000)
        try write(repoRoot.appendingPathComponent("\(small)/config.json"), bytes: 24)
        try write(repoRoot.appendingPathComponent("\(small)/.DS_Store"), bytes: 6)
        try write(repoRoot.appendingPathComponent("\(base)/config.json"), bytes: 20)
        try write(repoRoot.appendingPathComponent("\(base)/\(evictedFile)"), bytes: 500)

        let outside = temp.appendingPathComponent("Elsewhere", isDirectory: true)
        try write(outside.appendingPathComponent("big.bin"), bytes: 4096)
        try FileManager.default.createSymbolicLink(
            at: repoRoot.appendingPathComponent("\(base)/link.bin"),
            withDestinationURL: outside.appendingPathComponent("big.bin"),
        )
        try FileManager.default.createSymbolicLink(
            at: repoRoot.appendingPathComponent("openai_whisper-linked"),
            withDestinationURL: outside,
        )
        try write(repoRoot.appendingPathComponent("notes.txt"), bytes: 3)
        try write(repoRoot.appendingPathComponent("\(unknownVariant)/config.json"), bytes: 3)
        try write(repoRoot.appendingPathComponent(".hidden-variant/config.json"), bytes: 3)
        var flagged = repoRoot.appendingPathComponent("openai_whisper-flagged", isDirectory: true)
        try write(flagged.appendingPathComponent("config.json"), bytes: 3)
        var values = URLResourceValues()
        values.isHidden = true
        try flagged.setResourceValues(values)

        try write(tree.metadata(small).appendingPathComponent("config.json.metadata"), bytes: 3)
        try write(tree.metadata(base).appendingPathComponent("config.json.metadata"), bytes: 3)
        try write(repoRoot.appendingPathComponent(".cache/huggingface/.gitignore"), bytes: 1)

        try write(huggingface.appendingPathComponent("models/openai/whisper-small/tokenizer.json"), bytes: 3)
        try write(huggingface.appendingPathComponent("models/someone/other-model/model.bin"), bytes: 3)
        try write(tree.currentBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(small)/config.json"), bytes: 3)
        return tree
    }

    /// Everything that is not a stock variant or its metadata.
    func assertEverythingElseIsUntouched(file: StaticString = #filePath, line: UInt = #line) {
        let kept = [
            repoRoot.appendingPathComponent("openai_whisper-linked"),
            repoRoot.appendingPathComponent("notes.txt"),
            repoRoot.appendingPathComponent("\(Self.unknownVariant)/config.json"),
            repoRoot.appendingPathComponent(".hidden-variant/config.json"),
            repoRoot.appendingPathComponent("openai_whisper-flagged/config.json"),
            repoRoot.appendingPathComponent(".cache/huggingface/.gitignore"),
            huggingface.appendingPathComponent("models/openai/whisper-small/tokenizer.json"),
            huggingface.appendingPathComponent("models/someone/other-model/model.bin"),
            currentBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(Self.small)/config.json"),
            temp.appendingPathComponent("Elsewhere/big.bin"),
        ]
        for url in kept {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.path) was removed", file: file, line: line)
        }
    }
}

/// Stands in for the Trash: moves each item into `folder` and records it.
final class LegacyWhisperFakeTrash: @unchecked Sendable {
    let folder: URL
    var failing: Set<String> = []
    private(set) var trashed: [String] = []

    init(folder: URL) {
        self.folder = folder
    }

    func callAsFunction(_ url: URL) throws {
        if failing.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.moveItem(
            at: url,
            to: folder.appendingPathComponent("\(trashed.count)-\(url.lastPathComponent)"),
        )
        trashed.append(url.path)
    }
}
