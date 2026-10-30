import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WhisperKitModelMigration")

/// Moves WhisperKit models that earlier builds downloaded into
/// `Documents/huggingface` over to `WhisperKitLocalSnapshot.downloadBase` (why the
/// base moved is written there), so an existing install does not download a
/// gigabyte again.
///
/// Runs once per variant and process, off the main actor, and the engine awaits it
/// before its local lookup, so a load never looks at a half-moved tree. Only the
/// variant being loaded moves, with its Hub download metadata:
/// `Documents/huggingface` is shared by every tool built on swift-transformers, so
/// the folder as a whole is never moved. The tokenizer cache
/// (`models/openai/whisper-*`) is copied rather than moved: it is a few megabytes,
/// WhisperKit needs it offline, and another tool may be reading it.
///
/// Every failure is non-fatal: whatever is not moved stays where it was, the
/// locator finds nothing at the new location, and the engine downloads instead.
enum WhisperKitModelMigration {
    /// What `migrate` did, which is what the log line reports.
    enum Outcome: Equatable {
        /// A complete copy moved from the old location to the new one.
        case moved
        /// The new location already has the variant (complete or not), or another
        /// process moved it while this one tried. The old copy, if any, is left
        /// alone: replacing what a download put there could discard a newer model,
        /// and deleting the old one is the user's call.
        case keptCurrent
        /// No complete, fully local copy at the old location; the download fetches it.
        case nothingToMove
        case failed(String)
    }

    /// Where earlier builds wrote. Spelled out rather than read from the library
    /// default, because it names folders that already exist, which a later change
    /// of that default would not move. In the sandboxed build this is the
    /// container's own `Documents`, which iCloud does not sync.
    static let legacyDownloadBase: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("huggingface", isDirectory: true)

    /// `<base>/models/<repo>`, the layout earlier builds left on disk. Spelled out
    /// for the same reason as `legacyDownloadBase`, and because a `HubApiWrapper`
    /// would start a network path monitor just to build this path.
    static func legacyRepoRoot(for repoID: String, base: URL) -> URL {
        base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
    }

    /// Where the Hub downloader keeps a variant's per-file metadata (commit hash
    /// and etag) and its `.incomplete` partials: `<repo root>/.cache/huggingface/
    /// download/<variant>`, as `HubApi.snapshot` lays it out. The library keeps
    /// this internal, hence spelled out. Moved with the variant so a later
    /// download at the new base finds the files current instead of fetching them.
    static func downloadMetadataFolder(variant: String, in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// Bring `variant` of `repoID` over from the legacy location. The work runs once
    /// per variant and process, on a background task; every caller, including one
    /// that arrives while it runs, awaits that same run.
    static func migrateIfNeeded(repoID: String, variant: String) async {
        await runs.run(key: "\(repoID)/\(variant)") {
            migrateFromLegacyLocation(repoID: repoID, variant: variant)
        }
    }

    private static func migrateFromLegacyLocation(repoID: String, variant: String) {
        guard let legacyDownloadBase else { return }
        let legacyRoot = legacyRepoRoot(for: repoID, base: legacyDownloadBase)
        // Read through the prepared accessor: anything moved in lands in a folder
        // that already exists and is excluded from backup.
        _ = WhisperKitLocalSnapshot.downloadBase
        let outcome = migrate(variant: variant, from: legacyRoot, to: WhisperKitLocalSnapshot.repoRoot(for: repoID))
        // Independent of the model's outcome: a variant moved by an earlier run
        // that stopped before this step still needs its tokenizer.
        copyTokenizers(
            from: legacyRepoRoot(for: tokenizerOrg, base: legacyDownloadBase),
            to: WhisperKitLocalSnapshot.repoRoot(for: tokenizerOrg),
        )
        switch outcome {
        case .moved:
            logger.info("Moved WhisperKit model \(variant, privacy: .public) out of Documents")

        case .keptCurrent, .nothingToMove:
            break

        case let .failed(reason):
            logger.error(
                "Could not move WhisperKit model \(variant, privacy: .public) out of Documents, downloading instead: \(reason, privacy: .public)",
            )
        }
    }

    /// Move one variant folder, and its download metadata, from `legacyRepoRoot`
    /// to `repoRoot`. Moves only when nothing is at the destination and the old
    /// copy has every file a load needs, none of them an iCloud placeholder. Both
    /// roots, the file manager and the eviction check are parameters so this runs
    /// against temp folders in tests, never the real ones.
    static func migrate(
        variant: String,
        from legacyRepoRoot: URL,
        to repoRoot: URL,
        fileManager: FileManager = .default,
        isEvicted: (URL) -> Bool = isEvictedPlaceholder,
    ) -> Outcome {
        let source = legacyRepoRoot.appendingPathComponent(variant, isDirectory: true)
        let destination = repoRoot.appendingPathComponent(variant, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return .keptCurrent }
        guard isComplete(source, fileManager: fileManager, isEvicted: isEvicted) else { return .nothingToMove }
        do {
            try fileManager.createDirectory(at: repoRoot, withIntermediateDirectories: true)
            // Same volume in every normal setup, so this is a rename and not a copy.
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            // Another process (a second app instance, a parallel test run) may have
            // moved it first. Then the model is where it belongs, and saying
            // "downloading instead" would be wrong.
            if WhisperKitLocalSnapshot.requiredPaths().allSatisfy({ relative in
                fileManager.fileExists(atPath: destination.appendingPathComponent(relative).path)
            }) {
                return .keptCurrent
            }
            return .failed(String(describing: type(of: error)))
        }
        moveDownloadMetadata(variant: variant, from: legacyRepoRoot, to: repoRoot, fileManager: fileManager)
        return .moved
    }

    /// Best effort: without the metadata a later download re-checks every file
    /// against the Hub instead of trusting it, which costs time, not correctness.
    private static func moveDownloadMetadata(
        variant: String,
        from legacyRepoRoot: URL,
        to repoRoot: URL,
        fileManager: FileManager,
    ) {
        let source = downloadMetadataFolder(variant: variant, in: legacyRepoRoot)
        let destination = downloadMetadataFolder(variant: variant, in: repoRoot)
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path)
        else { return }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            logger.warning(
                "Could not move download metadata of \(variant, privacy: .public): \(String(describing: type(of: error)), privacy: .public)",
            )
        }
    }

    /// Copy every tokenizer folder (`whisper-*`) that is not yet at `root` and is
    /// fully on disk. Each copy is made under a temporary name next to its final
    /// place and renamed into it, so an interrupted copy never leaves a broken
    /// tokenizer that later runs would take for a finished one. Failures are
    /// skipped: WhisperKit fetches a missing tokenizer itself.
    static func copyTokenizers(
        from legacyRoot: URL,
        to root: URL,
        fileManager: FileManager = .default,
        isEvicted: (URL) -> Bool = isEvictedPlaceholder,
    ) {
        let names = (try? fileManager.contentsOfDirectory(atPath: legacyRoot.path)) ?? []
        for name in names where name.hasPrefix("whisper-") {
            let source = legacyRoot.appendingPathComponent(name, isDirectory: true)
            let destination = root.appendingPathComponent(name, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path),
                  !containsEvictedFile(source, fileManager: fileManager, isEvicted: isEvicted)
            else { continue }
            let staging = root.appendingPathComponent(".\(name).partial-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: staging)
                try fileManager.moveItem(at: staging, to: destination)
            } catch where fileManager.fileExists(atPath: destination.path) {
                // Another run put it in place first; its copy is whole by the same rule.
            } catch {
                logger.warning(
                    "Could not copy tokenizer \(name, privacy: .public) out of Documents: \(String(describing: type(of: error)), privacy: .public)",
                )
            }
        }
    }

    /// Whether `folder` has every file a load needs and nothing in it is an iCloud
    /// placeholder. With "Optimize Mac Storage" files may have been evicted; moved
    /// out of the synced folder they could no longer be read, so such a copy stays
    /// where it is and the model is downloaded instead. Every file is checked, not
    /// only the required ones, because WhisperKit also reads its configs.
    static func isComplete(
        _ folder: URL,
        fileManager: FileManager = .default,
        isEvicted: (URL) -> Bool = isEvictedPlaceholder,
    ) -> Bool {
        WhisperKitLocalSnapshot.requiredPaths().allSatisfy { relative in
            fileManager.fileExists(atPath: folder.appendingPathComponent(relative).path)
        } && !containsEvictedFile(folder, fileManager: fileManager, isEvicted: isEvicted)
    }

    /// Whether iCloud has evicted `file`, leaving only a placeholder on disk.
    static func isEvictedPlaceholder(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded
    }

    private static func containsEvictedFile(
        _ folder: URL,
        fileManager: FileManager,
        isEvicted: (URL) -> Bool,
    ) -> Bool {
        let key = URLResourceKey.ubiquitousItemDownloadingStatusKey
        guard let files = fileManager.enumerator(at: folder, includingPropertiesForKeys: [key]) else {
            return false
        }
        return files.contains { ($0 as? URL).map(isEvicted) ?? false }
    }

    /// The organisation the stock tokenizers are published under
    /// (`openai/whisper-<size>`), whose folder holds one subfolder per tokenizer.
    private static let tokenizerOrg = "openai"

    private static let runs = Runs()

    /// One background run per key, shared by every caller that asks for it.
    private actor Runs {
        private var tasks: [String: Task<Void, Never>] = [:]

        func run(key: String, _ work: @escaping @Sendable () -> Void) async {
            if let running = tasks[key] {
                await running.value
                return
            }
            let task = Task.detached(priority: .utility, operation: work)
            tasks[key] = task
            await task.value
        }
    }
}
