import Foundation
import WhisperKit

/// The three steps `WhisperKitEngine.loadModel()` takes to reach a usable pipe,
/// named so a test can observe which of them ran. Production resolves every step
/// against WhisperKit itself. Why the local step comes first is written down once,
/// on `WhisperKitLocalSnapshot`.
@MainActor
struct WhisperKitModelSource {
    /// The folder holding a complete local copy of the variant, or nil when it has
    /// to be fetched. Never touches the network.
    let locateLocal: (String) -> URL?
    /// WhisperKit's own downloader, which reaches the Hub before it inspects any
    /// local file.
    let download: (String, @escaping ProgressCallback) async throws -> URL
    /// Build the WhisperKit pipe from an on-disk model folder. It is also the
    /// completeness judge: `loadModels` checks its three CoreML bundles here, so a
    /// copy the locator waved through but CoreML cannot use still fails into the
    /// download.
    let makePipe: (String, URL) async throws -> WhisperKit

    /// The folder as WhisperKit needs it. Named and separate because the conversion
    /// is load-bearing and wrong by default. `WhisperKitConfig` takes a `String` and
    /// WhisperKit turns it straight back into `URL(fileURLWithPath:)`, while
    /// `URL.path()` percent-encodes: an account name with a space or a non-ASCII
    /// character would make the model this locator just found look absent, and
    /// offline that ends in a failed download instead of a loaded model.
    nonisolated static func modelFolderArgument(_ folder: URL) -> String {
        folder.path(percentEncoded: false)
    }

    static let production = Self(
        locateLocal: { variant in
            WhisperKitLocalSnapshot.locate(variant: variant, in: WhisperKitLocalSnapshot.defaultRepoRoot)
        },
        download: { variant, progress in
            // `from:` passed explicitly although it matches the library default:
            // the locator derives its root from the same constant, and a changed
            // default would otherwise have the two point at different repositories,
            // which shows up as "the model is never found".
            try await WhisperKit.download(
                variant: variant,
                from: WhisperKitLocalSnapshot.repoID,
                progressCallback: progress,
            )
        },
        makePipe: { variant, folder in
            try await WhisperKit(WhisperKitConfig(model: variant, modelFolder: modelFolderArgument(folder)))
        },
    )
}
