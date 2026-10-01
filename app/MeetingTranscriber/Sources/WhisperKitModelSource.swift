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
    /// WhisperKit's downloader sends the Hugging Face token it finds in the
    /// environment (`HF_TOKEN` or `HUGGING_FACE_HUB_TOKEN`) with every request, and
    /// the Hub answers a revoked or expired token with 401 even for a public
    /// repository. A token left in the environment by some other tool would then fail
    /// every download with "authentication required", for a model that needs no
    /// authentication at all. The token is still tried first, so a private or gated
    /// repository keeps working with a valid one. When the anonymous attempt fails
    /// too, the first error is the one reported, because it names the actual problem.
    ///
    /// `attempt` receives nil to let WhisperKit look the token up, and `""` for the
    /// retry: WhisperKit only falls back to its lookup for nil, so an empty string
    /// is what keeps the rejected token out. For an empty token WhisperKit sends no
    /// `Authorization` header on any request: the file listing, the HEAD requests
    /// and the file download alike.
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

    /// Whether `error` is the Hub refusing the request's credentials:
    /// `authorizationRequired(statusCode:)`, which WhisperKit throws for a 401 or
    /// 403 answer and, with nil, when it has no token where one is required.
    /// WhisperKit keeps its Hub error type internal, so it is matched by its fully
    /// qualified case name, whatever the status code, which
    /// `testRejectedTokenMatchesWhisperKitsOwnError` pins against the real type.
    nonisolated static func isRejectedToken(_ error: any Error) -> Bool {
        String(reflecting: error).hasPrefix("ArgmaxCore.Hub.HubClientError.authorizationRequired(")
    }

    /// Run a Hub download for `variant` (with the anonymous retry above) and accept
    /// only a folder of exactly that name.
    ///
    /// `WhisperKit.download` matches the variant as the glob `*<variant>/*` and
    /// returns the folder that matched, so a variant typed as the tail of the real
    /// folder name downloads fine: `large-v3_8bit` fetches
    /// `flix-swissgerman-large-v3_8bit`. The engine would load it once and then
    /// never again offline, because the locator looks for a folder of the typed
    /// name, finds none, and every later load goes back to the Hub (issue #736 for
    /// one model). A neighbour that merely ends in the variant could be picked the
    /// same way. Refusing the mismatch here turns that into one error that names
    /// the exact folder. The files the refused download left in the cache sit under
    /// the real name, where the locator never serves them for the typed one.
    static func downloadExactly(
        _ variant: String,
        _ attempt: (String?) async throws -> URL,
    ) async throws -> URL {
        let folder = try await downloadRetryingAnonymously(attempt)
        guard folder.lastPathComponent == variant else {
            throw WhisperKitModelError.variantNameMismatch(requested: variant, repositoryFolder: folder.lastPathComponent)
        }
        return folder
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
                try await downloadExactly(variant) { token in
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
    /// The folder is checked for the tokenizer too, unlike a Hub variant, so that
    /// it is self-sufficient. It is not the first place WhisperKit looks: a stock
    /// tokenizer already cached under `models/openai/whisper-<detected size>` takes
    /// precedence, the folder's own `tokenizer.json` comes next, and the Hub is
    /// the fallback when neither is there or the local one fails to parse (no
    /// `tokenizerFolder` is passed). A folder that carries its tokenizer therefore
    /// loads without the Hub whether or not that cache exists. Sandbox access goes
    /// through `VocabularyFileAccess`, whose two helpers are not specific to
    /// vocabulary.
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
