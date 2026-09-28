import Foundation

/// Where the files of a WhisperKit model variant come from.
///
/// Part of a model's identity next to its variant name: a fine-tune usually keeps
/// the folder name of the model it was trained from, so two origins can carry a
/// variant of the same name. `WhisperKitEngine` therefore treats a change of origin
/// exactly like a change of variant.
enum WhisperKitModelOrigin: Equatable, Sendable {
    /// A Hugging Face repository laid out like argmaxinc/whisperkit-coreml, one
    /// folder per variant. Fetched into WhisperKit's download cache on first use and
    /// loaded from there afterwards without contacting the Hub.
    case hub(repoID: String)

    /// A model folder picked on disk. Loaded where it is and never downloaded.
    /// `bookmark` keeps the sandboxed build's access across relaunches, the same way
    /// the custom vocabulary file does.
    case localFolder(path: String, bookmark: Data?)

    /// The repository the stock variants in the model picker come from.
    static let stock = Self.hub(repoID: WhisperKitLocalSnapshot.repoID)
}

/// Why a picked model folder cannot be loaded, worded for the user.
enum WhisperKitModelError: LocalizedError, Equatable {
    /// The folder is gone, or its sandbox grant no longer resolves.
    case folderUnavailable
    /// A file a load needs is not in the folder. `missing` is relative to it.
    case folderIncomplete(missing: String)
    /// Every file is there and WhisperKit still refused it; its own error is logged.
    case folderNotLoadable

    /// Also shown as it is by the Settings validation line.
    var message: String {
        switch self {
        case .folderUnavailable: "Model folder cannot be read."
        case let .folderIncomplete(missing): "Model folder is missing \(missing)."
        case .folderNotLoadable: "Model folder could not be loaded by WhisperKit."
        }
    }

    var errorDescription: String? {
        message
    }
}
