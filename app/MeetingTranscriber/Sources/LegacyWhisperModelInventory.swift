import Foundation

/// A WhisperKit variant folder an earlier build left in `Documents/huggingface`.
struct LegacyWhisperModel: Equatable {
    /// The folder name, which is the variant name (`openai_whisper-small`).
    let variant: String
    /// What the folder's files occupy on this Mac. An iCloud-evicted file counts
    /// zero: only its placeholder is here.
    let bytes: Int64
}

/// Finds and removes the WhisperKit models earlier builds left in
/// `Documents/huggingface`, which iCloud keeps syncing (issue #640).
///
/// `WhisperKitModelMigration` moves a variant only when it is loaded, and leaves
/// the old copy when the new location already has one, so variants stay behind.
/// Removing them is the user's decision, made in Settings; this type only lists
/// and trashes.
///
/// The scope is deliberately narrow, and still not narrow enough to tell this
/// app's copy from another tool's: a folder name is all there is. So nothing is
/// removed in bulk; the user picks each variant and is told the folder is shared.
///
/// Only the stock repository's folder,
/// `Documents/huggingface/models/argmaxinc/whisperkit-coreml`, is looked at, and
/// in it only the variants this app could have downloaded, plus each one's own
/// download metadata. `Documents/huggingface` is shared by every tool built on
/// swift-transformers, and the stock repository folder by every WhisperKit tool
/// that keeps the library default, so nothing else is ours to remove: not the
/// tokenizer cache, not the repository's other metadata, not a variant only
/// another tool uses, not another repository. A custom repository is left out as
/// well, because which ones an earlier build used is not known.
///
/// Two variants that qualify by name stay anyway (see `Scope`): one a picked
/// model folder points into, and the selected one while the migration would
/// still move it on the next load.
///
/// Removal goes to the Trash, never a hard delete, so a mistaken click can be
/// undone from Finder.
enum LegacyWhisperModelInventory {
    /// One item that could not be moved to the Trash.
    struct Failure: Equatable {
        let item: String
        let reason: String
    }

    /// What may be listed and removed, decided from the settings at the time of
    /// the scan and again at the time of the removal.
    struct Scope {
        /// The repository folder at the old location.
        let repoRoot: URL
        /// The same repository where models live now, as the engine looks it up.
        let currentRepoRoot: URL
        /// Where models live now. Nothing is listed or removed when it overlaps
        /// `repoRoot`, since then a "leftover" could be the model in use.
        let currentBase: URL
        /// The variants this app could have downloaded into `repoRoot`, case-folded:
        /// the volume ignores case, and so does the migration's path lookup.
        let knownVariants: Set<String>
        /// Model folders loaded in place; a variant one of them points into stays.
        let pickedFolders: [URL]
        /// The selected variant of this repository. It stays while it is complete
        /// at the old location and absent at the new one, because then the
        /// migration moves it on the next load instead of downloading it again.
        let selectedVariant: String?

        /// The old folder comes from the migration's helper and the new one from
        /// `WhisperKitLocalSnapshot.repoRoot(for:)`, the lookup the engine and the
        /// migration use, so none of them can name a different folder. Tests pass
        /// `currentRepoRoot` to point it at a temp tree.
        init(
            legacyBase: URL,
            knownVariants: Set<String>,
            currentBase: URL = WhisperKitLocalSnapshot.downloadBaseLocation,
            currentRepoRoot: URL? = nil,
            pickedFolders: [URL] = [],
            selectedVariant: String? = nil,
            repoID: String = WhisperKitLocalSnapshot.repoID,
        ) {
            repoRoot = WhisperKitModelMigration.legacyRepoRoot(for: repoID, base: legacyBase)
            self.currentRepoRoot = currentRepoRoot ?? WhisperKitLocalSnapshot.repoRoot(for: repoID)
            self.currentBase = currentBase
            self.knownVariants = Set(knownVariants.map { $0.lowercased() })
            self.pickedFolders = pickedFolders
            self.selectedVariant = selectedVariant
        }
    }

    /// Whether `url` is in a folder iCloud syncs: false when "Desktop &
    /// Documents" is off. The row still shows then, only without the iCloud
    /// wording, because the models still take a gigabyte each of disk that
    /// nothing else reclaims. (The App Store build leaves the row out; see
    /// `EngineController.makeLegacyWhisperModels`.)
    static func isSyncedToICloud(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// The removable variant folders, sorted by name, each with its size. A
    /// missing folder lists nothing; any other failure to read it throws, so the
    /// row can say so instead of looking as if nothing were left.
    static func scan(
        _ scope: Scope,
        fileManager: FileManager = .default,
        isEvicted: (URL) -> Bool = WhisperKitModelMigration.isEvictedPlaceholder,
    ) throws -> [LegacyWhisperModel] {
        guard !overlapsCurrentLocation(scope) else { return [] }
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: scope.repoRoot.path)
        } catch where isNoSuchFile(error) {
            return []
        }
        return entries.sorted()
            .filter { isRemovable($0, in: scope, fileManager: fileManager, isEvicted: isEvicted) }
            .map { variant in
                let folder = scope.repoRoot.appendingPathComponent(variant, isDirectory: true)
                return LegacyWhisperModel(
                    variant: variant,
                    bytes: localBytes(in: folder, fileManager: fileManager, isEvicted: isEvicted),
                )
            }
    }

    /// Move each variant folder to the Trash, then its download metadata
    /// (`WhisperKitModelMigration.downloadMetadataFolder`), which describes that
    /// variant's files and nothing else. Each folder is checked again right
    /// before it goes, against `scope`, since the disk or the settings may have
    /// changed since the scan, and under the migration's lock, so a load cannot
    /// move the folder while it is being trashed. A variant whose folder is
    /// already gone still has its metadata trashed, which would otherwise stay
    /// in `Documents` with nothing left to list it by. Returns what could not be
    /// moved; the rest is in the Trash.
    static func moveToTrash(
        _ models: [LegacyWhisperModel],
        scope: Scope,
        fileManager: FileManager = .default,
        isEvicted: (URL) -> Bool = WhisperKitModelMigration.isEvictedPlaceholder,
        trash: (URL) throws -> Void = systemTrash,
    ) -> [Failure] {
        guard !overlapsCurrentLocation(scope) else {
            return models.map { Failure(item: $0.variant, reason: "It is in the folder the app uses now.") }
        }
        return models.flatMap { model in
            WhisperKitModelMigration.withLegacyFolderLock(variant: model.variant) {
                moveToTrash(model.variant, scope: scope, fileManager: fileManager, isEvicted: isEvicted, trash: trash)
            }
        }
    }

    private static func moveToTrash(
        _ variant: String,
        scope: Scope,
        fileManager: FileManager,
        isEvicted: (URL) -> Bool,
        trash: (URL) throws -> Void,
    ) -> [Failure] {
        let folder = scope.repoRoot.appendingPathComponent(variant, isDirectory: true)
        // Only "no such file" means gone. Any other failure to look (no
        // permission, a privacy prompt declined) is reported, never taken for
        // a folder that is already gone.
        let gone: Bool
        do {
            _ = try fileManager.attributesOfItem(atPath: folder.path)
            gone = false
        } catch where isNoSuchFile(error) {
            gone = true
        } catch {
            return [Failure(item: variant, reason: reason(for: error))]
        }
        if !gone {
            guard isRemovable(variant, in: scope, fileManager: fileManager, isEvicted: isEvicted) else {
                return [Failure(item: variant, reason: "It is no longer an unused model folder.")]
            }
            do {
                try trash(folder)
            } catch where isNoSuchFile(error) {
                // Gone in the meantime; its metadata can still go.
            } catch {
                return [Failure(item: variant, reason: reason(for: error))]
            }
        } else if !isKnown(variant, in: scope) {
            return [Failure(item: variant, reason: "It is no longer an unused model folder.")]
        }
        let metadata = WhisperKitModelMigration.downloadMetadataFolder(variant: variant, in: scope.repoRoot)
        guard isRealDirectory(metadata), isInside(metadata, scope.repoRoot) else { return [] }
        // With the variant folder gone, partial files mean a download may be
        // writing here right now: another WhisperKit tool fetching this variant,
        // whose state nobody showed the user. (Next to a variant folder the user
        // ticked, partials are this copy's own leftovers and go with it.)
        guard !(gone && containsPartialDownload(metadata, fileManager: fileManager)) else {
            return [Failure(item: "\(variant) download metadata", reason: "A download is in progress there.")]
        }
        do {
            try trash(metadata)
            return []
        } catch {
            return [Failure(item: "\(variant) download metadata", reason: reason(for: error))]
        }
    }

    /// The real Trash. Recoverable from Finder, unlike `removeItem`.
    static let systemTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Text

    private static func formattedSize(_ models: [LegacyWhisperModel]) -> String {
        ByteCountFormatter.string(fromByteCount: models.reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }

    /// The Settings row: "Old models in Documents: 2 (1.9 GB), synced to iCloud".
    static func summary(_ models: [LegacyWhisperModel], syncedToICloud: Bool) -> String {
        let text = "Old models in Documents: \(models.count) (\(formattedSize(models)))"
        return syncedToICloud ? text + ", synced to iCloud" : text
    }

    /// Under the summary: a folder name cannot tell this app's copy from another
    /// tool's, so the user is the one who knows.
    static let sharedFolderNote = "Other apps that use WhisperKit can share this folder. "
        + "Select only copies you know no app uses."

    /// One row per variant: "openai_whisper-small (480 MB)".
    static func rowLabel(_ model: LegacyWhisperModel) -> String {
        "\(model.variant) (\(formattedSize([model])))"
    }

    /// What the confirmation asks about. Trashing a synced folder also removes it
    /// from iCloud Drive, and with that from the user's other Macs. "This app no
    /// longer reads these copies" holds for every listed variant: the one this
    /// app would still move over, and one a picked folder points into, are never
    /// listed.
    static func confirmationMessage(_ models: [LegacyWhisperModel], syncedToICloud: Bool) -> String {
        let iCloud = syncedToICloud ? "They are also removed from iCloud Drive, so from your other Macs too. " : ""
        return "\(models.map(\.variant).joined(separator: ", ")) (\(formattedSize(models))) will be moved to the Trash. "
            + iCloud
            + "Other apps that use WhisperKit can share this folder; move only copies you know no app uses. "
            + "This app no longer reads these copies; selecting one of these models again downloads it."
    }

    /// One line per item that stayed, or nil when everything went.
    static func failureMessage(_ failures: [Failure]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures.map { "Could not move \($0.item) to the Trash: \($0.reason)" }.joined(separator: "\n")
    }

    // MARK: - Checks

    /// `name` is a known variant naming a real, visible directory in the
    /// repository folder (not a symlink to one), no picked model folder overlaps
    /// it, and it is not the selected variant the migration still needs.
    private static func isRemovable(
        _ name: String,
        in scope: Scope,
        fileManager: FileManager,
        isEvicted: (URL) -> Bool,
    ) -> Bool {
        guard isKnown(name, in: scope) else { return false }
        let folder = scope.repoRoot.appendingPathComponent(name, isDirectory: true)
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]),
              isRealDirectory(values), values.isHidden != true,
              !scope.pickedFolders.contains(where: { overlaps($0, folder) }),
              // The copy in use, reached through a symlink at the new location.
              !overlaps(scope.currentRepoRoot.appendingPathComponent(name, isDirectory: true), folder)
        else { return false }
        guard let selected = scope.selectedVariant, name.caseInsensitiveCompare(selected) == .orderedSame else {
            return true
        }
        return WhisperKitModelMigration.decision(
            variant: name,
            from: scope.repoRoot,
            to: scope.currentRepoRoot,
            fileManager: fileManager,
            isEvicted: isEvicted,
        ) != .willMove
    }

    /// The old folder overlaps where models live now, at the base or at the
    /// repository (a symlink either way): a "leftover" could be the copy in use.
    private static func overlapsCurrentLocation(_ scope: Scope) -> Bool {
        overlaps(scope.repoRoot, scope.currentBase) || overlaps(scope.repoRoot, scope.currentRepoRoot)
    }

    /// Whether `error` says the item does not exist, as opposed to any other
    /// reason it could not be read.
    private static func isNoSuchFile(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map(isNoSuchFile) ?? false
    }

    /// A known variant, compared ignoring case, and a valid, visible folder name
    /// by the same rule the settings apply to a typed variant.
    private static func isKnown(_ name: String, in scope: Scope) -> Bool {
        scope.knownVariants.contains(name.lowercased()) && AppSettings.isValidVariant(name) && !name.hasPrefix(".")
    }

    /// Whether the Hub downloader is midway through a file there: it keeps each
    /// file as `<name>.incomplete` until it is whole.
    private static func containsPartialDownload(_ folder: URL, fileManager: FileManager) -> Bool {
        guard let files = fileManager.enumerator(atPath: folder.path) else { return false }
        return files.contains { ($0 as? String)?.hasSuffix(".incomplete") == true }
    }

    /// Why a move failed, without the path a Foundation error description can
    /// carry, which would put the account name into the Settings window.
    static func reason(for error: any Error) -> String {
        switch (error as? CocoaError)?.code {
        case .fileReadNoPermission, .fileWriteNoPermission:
            "Permission denied."

        case .fileNoSuchFile, .fileReadNoSuchFile:
            "It no longer exists."

        default:
            "Error \((error as NSError).domain) \((error as NSError).code)."
        }
    }

    /// A directory, and not a symlink to one. Resource values describe the link
    /// itself, so a symlink already reports `isDirectory == false`; the symlink
    /// check states the rule outright instead of leaning on that.
    private static func isRealDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map(isRealDirectory) ?? false
    }

    private static func isRealDirectory(_ values: URLResourceValues) -> Bool {
        values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Bytes the regular files under `folder` occupy on disk, an evicted one
    /// counting zero. Symlinks are not followed, so nothing outside the folder is
    /// counted. The download status is prefetched too, so the real eviction check
    /// reads it from the enumerator's cache instead of asking once more per file.
    private static func localBytes(in folder: URL, fileManager: FileManager, isEvicted: (URL) -> Bool) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .ubiquitousItemDownloadingStatusKey]
        guard let files = fileManager.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  !isEvicted(file)
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Whether one of the two folders, symlinks resolved, contains the other.
    private static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        isInside(lhs, rhs) || isInside(rhs, lhs)
    }

    /// Whether `url` is `folder` or below it. Compared by file identity, walking
    /// up from `url`, because spellings mislead: APFS is usually case-insensitive,
    /// and symlinks or firmlinks give one folder several paths. Only when `folder`
    /// does not exist, so has no identity, are the paths compared, symlinks
    /// resolved and ignoring case, which errs towards "inside": every caller
    /// treats that as the cautious answer, or knows `folder` exists.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let rootID = fileIdentity(root) else {
            let path = target.path.lowercased()
            let rootPath = root.path.lowercased()
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
        var path = target.path
        while true {
            if let id = fileIdentity(path), id.isEqual(rootID) { return true }
            guard path != "/", !path.isEmpty else { return false }
            path = parentPath(path)
        }
    }

    /// `/a/b` → `/a`, `/a` → `/`. Paths here are standardized: absolute, no
    /// trailing slash except on the root.
    private static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    private static func fileIdentity(_ url: URL) -> (any NSObjectProtocol)? {
        fileIdentity(url.path)
    }

    /// From a fresh URL each time: resource values are cached per URL instance.
    private static func fileIdentity(_ path: String) -> (any NSObjectProtocol)? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }
}
