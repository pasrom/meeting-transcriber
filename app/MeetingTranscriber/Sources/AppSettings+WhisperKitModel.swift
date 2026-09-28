import Foundation

/// The WhisperKit model the settings ask for: a variant and where it comes from.
struct WhisperKitModelSelection: Equatable {
    let variant: String
    let origin: WhisperKitModelOrigin
}

enum WhisperKitCustomModelValidation: Equatable {
    case notConfigured
    case invalidRepository
    case invalidVariant
    case repository(repoID: String, variant: String)
    case folder(WhisperKitModelError)
    case folderReady

    var message: String {
        switch self {
        case .notConfigured:
            "Enter a Hugging Face repository and variant, or choose a model folder. Until then the stock model is used."

        case .invalidRepository:
            "Repository must look like owner/name. Until then the stock model is used."

        case .invalidVariant:
            "Variant must be the name of one folder in the repository. Until then the stock model is used."

        case let .repository(repoID, variant):
            "Downloads \(variant) from \(repoID) on first use, then loads it offline."

        case let .folder(problem):
            problem.message

        case .folderReady:
            "Model folder contains a complete WhisperKit model."
        }
    }
}

/// Custom WhisperKit model: a variant from another Hugging Face repository, or a
/// model folder on disk, used in place of the stock variants (for example a
/// fine-tune for a dialect). The folder is handled like the custom vocabulary file:
/// the plain path is kept for display, reads go through the security-scoped
/// bookmark so the sandboxed build keeps access after a relaunch.
extension AppSettings {
    /// The model the WhisperKit engine should load.
    ///
    /// A folder wins over a repository, since picking one is the more deliberate
    /// act. A custom model that is not filled in yet resolves to the stock variant
    /// in `whisperKitModel`, so an empty or malformed entry loads nothing new; one
    /// that is filled in is used as entered, even when the folder turns out to be
    /// incomplete, so the load fails with the reason instead of quietly running
    /// another model. What counts as "entered" is decided in Settings: each field
    /// hands its value over on Return or when it is left (`DraftTextField`), no
    /// longer on every keystroke, because the engine observer acts on every write
    /// here. Each field commits on its own, so changing the repository and then the
    /// variant is two commits, and in between the new repository is paired with
    /// the old variant.
    var whisperKitModelSelection: WhisperKitModelSelection {
        let stock = WhisperKitModelSelection(variant: whisperKitModel, origin: .stock)
        guard whisperKitCustomModelEnabled else { return stock }
        if !whisperKitCustomModelFolderPath.isEmpty {
            return WhisperKitModelSelection(
                variant: URL(fileURLWithPath: whisperKitCustomModelFolderPath).lastPathComponent,
                origin: .localFolder(path: whisperKitCustomModelFolderPath, bookmark: whisperKitCustomModelFolderBookmark),
            )
        }
        let repoID = whisperKitCustomRepo.trimmingCharacters(in: .whitespaces)
        let variant = whisperKitCustomVariant.trimmingCharacters(in: .whitespaces)
        guard Self.isValidRepoID(repoID), Self.isValidVariant(variant) else { return stock }
        return WhisperKitModelSelection(variant: variant, origin: .hub(repoID: repoID))
    }

    func setWhisperKitCustomModelFolder(_ url: URL) {
        let bookmark = VocabularyFileAccess.withAccess(to: url, VocabularyFileAccess.makeBookmark)
        updateWhisperKitCustomModelFolder(path: url.path, bookmark: bookmark)
    }

    /// Re-create the bookmark when macOS reports it stale (the folder moved or was
    /// renamed), and show the folder's current path. Called once at launch next to
    /// the vocabulary and output-folder repairs, off the view-update path. A stale
    /// bookmark still resolves, so this is about the shown path and the stored
    /// data staying current, not about the next load. No-op without a bookmark or
    /// while it is current.
    func repairStaleWhisperKitCustomModelFolderBookmark() {
        guard let bookmark = whisperKitCustomModelFolderBookmark,
              let repaired = VocabularyFileAccess.refreshedStaleBookmark(bookmark)
        else { return }
        updateWhisperKitCustomModelFolder(path: repaired.url.path, bookmark: repaired.bookmark)
    }

    /// Handles manual path edits. A bookmark is tied to its original URL, so keeping
    /// it after a different path was typed would load the wrong folder.
    func setWhisperKitCustomModelFolderPath(_ path: String) {
        guard path != whisperKitCustomModelFolderPath else { return }
        updateWhisperKitCustomModelFolder(path: path, bookmark: nil)
    }

    /// Back to the repository fields. The one way to leave a picked folder that
    /// needs no typing, which matters in the sandboxed build where a typed path
    /// carries no grant anyway.
    func clearWhisperKitCustomModelFolder() {
        updateWhisperKitCustomModelFolder(path: "", bookmark: nil)
    }

    func refreshWhisperKitCustomModelValidation() {
        whisperKitCustomModelValidation = currentWhisperKitCustomModelValidation()
    }

    /// For an edit to the repository or variant. While a folder is set it wins and
    /// the validation line describes the folder, so there is nothing to recompute,
    /// and recomputing would resolve the folder's bookmark and walk its files on
    /// the main actor for a field that does not even apply.
    func refreshWhisperKitRepositoryValidation() {
        guard whisperKitCustomModelFolderPath.isEmpty else { return }
        refreshWhisperKitCustomModelValidation()
    }

    private func currentWhisperKitCustomModelValidation() -> WhisperKitCustomModelValidation {
        if !whisperKitCustomModelFolderPath.isEmpty {
            // Fail-fast resolution: this runs in `init` and on the view path, where
            // a bookmark on a detached volume must not block the main actor. The
            // load resolves with the full options (`WhisperKitModelSource`).
            guard let folder = VocabularyFileAccess.resolve(
                path: whisperKitCustomModelFolderPath,
                bookmark: whisperKitCustomModelFolderBookmark,
                options: VocabularyFileAccess.failFastScopedResolution,
            ) else { return .folder(.folderUnavailable) }
            let problem = VocabularyFileAccess.withAccess(to: folder, WhisperKitLocalSnapshot.checkModelFolder)
            return problem.map(WhisperKitCustomModelValidation.folder) ?? .folderReady
        }
        let repoID = whisperKitCustomRepo.trimmingCharacters(in: .whitespaces)
        let variant = whisperKitCustomVariant.trimmingCharacters(in: .whitespaces)
        if repoID.isEmpty, variant.isEmpty { return .notConfigured }
        guard Self.isValidRepoID(repoID) else { return .invalidRepository }
        guard Self.isValidVariant(variant) else { return .invalidVariant }
        return .repository(repoID: repoID, variant: variant)
    }

    /// `owner/name`, in the characters Hugging Face allows in either part.
    static func isValidRepoID(_ repoID: String) -> Bool {
        let parts = repoID.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { isValidPathComponent(String($0)) }
    }

    /// One folder name. The variant becomes a path component under the download
    /// cache and a glob for WhisperKit's downloader, so separators, `..` and glob
    /// characters are rejected rather than escaped.
    static func isValidVariant(_ variant: String) -> Bool {
        isValidPathComponent(variant)
    }

    private static func isValidPathComponent(_ component: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return !component.isEmpty
            && component != "."
            && component != ".."
            && component.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}
