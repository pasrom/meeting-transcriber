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

    /// Run a Hub download with the token WhisperKit finds on its own, and once more
    /// without any token when the Hub turns that token away.
    ///
    /// WhisperKit's downloader sends whatever Hugging Face token the machine carries
    /// (`HF_TOKEN`, `~/.cache/huggingface/token`, and a few more places) with every
    /// request, and the Hub answers a revoked or expired token with 401 even for a
    /// public repository. A token left behind by some other tool would then fail
    /// every download with "authentication required", for a model that needs no
    /// authentication at all. The token is still tried first, so a private or gated
    /// repository keeps working with a valid one. When the anonymous attempt fails
    /// too, the first error is the one reported, because it names the actual problem.
    ///
    /// `attempt` receives nil to let WhisperKit look the token up, and `""` for no
    /// token: WhisperKit only falls back to its lookup for nil, and sends no
    /// `Authorization` header for an empty token.
    static func downloadRetryingAnonymously(
        _ attempt: (String?) async throws -> URL,
    ) async throws -> URL {
        do {
            return try await attempt(nil)
        } catch where isRejectedToken(error) {
            do {
                return try await attempt("")
            } catch _ {
                throw error
            }
        }
    }

    /// Whether `error` is the Hub refusing the request's credentials. WhisperKit
    /// keeps its Hub error type internal, so it is matched by its fully qualified
    /// name, which `testRejectedTokenMatchesWhisperKitsOwnError` pins against the
    /// real type.
    nonisolated static func isRejectedToken(_ error: any Error) -> Bool {
        String(reflecting: error) == "ArgmaxCore.Hub.HubClientError.authorizationRequired"
    }

    /// Resolve every step against WhisperKit itself, for the model's origin.
    static func production(for origin: WhisperKitModelOrigin) -> Self {
        switch origin {
        case let .hub(repoID):
            hub(repoID: repoID)

        case let .localFolder(path, bookmark):
            localFolder(path: path, bookmark: bookmark)
        }
    }

    private static func hub(repoID: String) -> Self {
        Self(
            locateLocal: { variant in
                WhisperKitLocalSnapshot.locate(variant: variant, in: WhisperKitLocalSnapshot.repoRoot(for: repoID))
            },
            download: { variant, progress in
                // `from:` passed explicitly although it matches the library default
                // for the stock models: the locator derives its root from the same
                // id, and a changed default would otherwise have the two point at
                // different repositories, which shows up as "the model is never found".
                try await downloadRetryingAnonymously { token in
                    try await WhisperKit.download(
                        variant: variant,
                        from: repoID,
                        token: token,
                        progressCallback: progress,
                    )
                }
            },
            makePipe: { variant, folder in
                try await WhisperKit(WhisperKitConfig(model: variant, modelFolder: modelFolderArgument(folder)))
            },
        )
    }

    /// A picked folder is loaded where it is. There is nothing to download it from,
    /// so the locator is the only way in, and the download step reports what the
    /// folder lacks instead: that is the error the engine logs when the load fails.
    ///
    /// The folder is checked for the tokenizer too, unlike a Hub variant, because
    /// WhisperKit fetches a tokenizer it cannot find locally from the Hub, and a
    /// picked folder is expected to load offline. Sandbox access goes through
    /// `VocabularyFileAccess`, whose two helpers are not specific to vocabulary.
    private static func localFolder(path: String, bookmark: Data?) -> Self {
        Self(
            locateLocal: { _ in
                guard let folder = VocabularyFileAccess.resolve(path: path, bookmark: bookmark) else { return nil }
                let problem = VocabularyFileAccess.withAccess(to: folder, WhisperKitLocalSnapshot.checkModelFolder)
                return problem == nil ? folder : nil
            },
            download: { _, _ in
                guard let folder = VocabularyFileAccess.resolve(path: path, bookmark: bookmark) else {
                    throw WhisperKitModelError.folderUnavailable
                }
                // A folder that checks out and still arrives here was refused by
                // WhisperKit itself, whose error the local branch has already logged.
                throw VocabularyFileAccess.withAccess(to: folder, WhisperKitLocalSnapshot.checkModelFolder)
                    ?? WhisperKitModelError.folderNotLoadable
            },
            makePipe: { variant, folder in
                // Held for the whole init: WhisperKit reads the CoreML bundles and
                // the tokenizer inside it. `folder` is the URL the locator resolved
                // from the bookmark, which is the one that carries the grant.
                let accessing = folder.startAccessingSecurityScopedResource()
                defer {
                    if accessing { folder.stopAccessingSecurityScopedResource() }
                }
                return try await WhisperKit(WhisperKitConfig(model: variant, modelFolder: modelFolderArgument(folder)))
            },
        )
    }
}
