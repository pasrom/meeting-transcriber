import Foundation
import WhisperKit

/// The one sentence a failed WhisperKit model load is reported with: in Settings
/// next to the model state, and in the error text of the job that needed the
/// model (`TranscriptionError.modelNotLoaded(reason:)`).
///
/// Worded here rather than taken from the error's own description, because the
/// likely errors carry a path: WhisperKit's `modelsUnavailable("Model file not
/// found at <path>")`, and any Cocoa file error. Both go into a notification and
/// the automation API, where a path would carry the account name. So only text
/// this app owns or knows to be path-free is shown as it is; everything else
/// collapses to a sentence that names the kind of failure.
enum WhisperKitLoadFailureReason {
    static func describe(_ error: any Error, variant: String, origin: WhisperKitModelOrigin) -> String {
        if let problem = error as? WhisperKitModelError {
            // The same sentence the Settings validation line shows for the folder.
            return problem.message
        }
        if WhisperKitModelSource.isRejectedToken(error) {
            return "Hugging Face refused the request: the repository may be private, "
                + "or the token set in HF_TOKEN or HUGGING_FACE_HUB_TOKEN is no longer valid."
        }
        if case let .hub(repoID) = origin, case let WhisperError.modelsUnavailable(message) = error {
            // The two outcomes of WhisperKit's folder search, told apart by the prefix
            // of its message; neither carries a path, but the message also carries
            // the search glob and the repository's debug description, so it is
            // reworded rather than shown.
            if message.hasPrefix("No models found") {
                return "\(repoID) has no folder named \(variant)."
            }
            if message.hasPrefix("Multiple models found") {
                return "\(repoID) has more than one folder ending in \(variant); the variant must be the full folder name."
            }
        }
        if error is URLError || isPathFreeHubError(error) {
            return "The download from Hugging Face failed: \(error.localizedDescription)"
        }
        if error is WhisperError {
            return "WhisperKit could not load the model files."
        }
        return "The model could not be loaded (\(String(describing: type(of: error))))."
    }

    /// The Hub error cases whose description carries at most a file name or a
    /// status code. `jsonSerialization` and `fileSystemError` wrap a file URL or a
    /// Cocoa error and are left out. Matched by qualified name like
    /// `WhisperKitModelSource.isRejectedToken`, since the type is internal to
    /// WhisperKit.
    private static let pathFreeHubErrorCases = [
        "httpStatusCode", "downloadError", "fileNotFound", "networkError", "resourceNotFound", "unexpectedError", "parse",
    ]

    private static func isPathFreeHubError(_ error: any Error) -> Bool {
        let name = String(reflecting: error)
        let prefix = "ArgmaxCore.Hub.HubClientError."
        guard name.hasPrefix(prefix) else { return false }
        let caseName = name.dropFirst(prefix.count).prefix { $0 != "(" }
        return pathFreeHubErrorCases.contains(String(caseName))
    }
}
