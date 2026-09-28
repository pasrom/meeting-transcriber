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
    /// in `whisperKitModel`, so a half-typed repository never costs a recording; one
    /// that is filled in is used even when the folder turns out to be incomplete, so
    /// the load fails with the reason instead of quietly running another model.
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
        let bookmark = VocabularyFileAccess.withAccess(to: url) { scopedURL in
            try? scopedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil,
            )
        }
        updateWhisperKitCustomModelFolder(path: url.path, bookmark: bookmark)
    }

    /// Handles manual path edits. A bookmark is tied to its original URL, so keeping
    /// it after a different path was typed would load the wrong folder.
    func setWhisperKitCustomModelFolderPath(_ path: String) {
        guard path != whisperKitCustomModelFolderPath else { return }
        updateWhisperKitCustomModelFolder(path: path, bookmark: nil)
    }

    func refreshWhisperKitCustomModelValidation() {
        whisperKitCustomModelValidation = currentWhisperKitCustomModelValidation()
    }

    private func currentWhisperKitCustomModelValidation() -> WhisperKitCustomModelValidation {
        if !whisperKitCustomModelFolderPath.isEmpty {
            guard let folder = VocabularyFileAccess.resolve(
                path: whisperKitCustomModelFolderPath,
                bookmark: whisperKitCustomModelFolderBookmark,
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
