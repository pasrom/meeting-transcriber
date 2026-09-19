import Foundation
import os.log
import WhisperKit

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WhisperKitLocalSnapshot")

/// Where WhisperKit keeps its downloaded models, and whether a complete copy of
/// a variant is already sitting there.
///
/// This is the one place the reason for the local-first load path is written
/// down. `WhisperKit.download` cannot serve an already-present model without the
/// network: its first step is `hubApi.getFilenames`, an unconditional GET against
/// huggingface.co, so a complete local model still fails the moment that host is
/// unreachable (issue #736). WhisperKit's own offline branch lives in
/// `HubApi.snapshot`, behind that call, and is gated on `NWPathMonitor`, which
/// reports a satisfied path when only huggingface.co is filtered rather than the
/// whole network being down. Identical in WhisperKit 1.0.0 and 1.1.0, so a
/// version pin does not undo it.
///
/// **When to delete this type:** once `WhisperKit.download` returns a local
/// snapshot without contacting the Hub, the way FluidAudio's `AsrModels.download`
/// already does with its `modelsExist` early-out. Then `loadModel()` can call the
/// downloader unconditionally again and this file goes away.
enum WhisperKitLocalSnapshot {
    /// The repository `WhisperKit.download` defaults to. Passed explicitly to the
    /// downloader as well, so the locator and the download cannot end up pointing
    /// at different repositories.
    static let repoID = "argmaxinc/whisperkit-coreml"

    /// The CoreML bundles `WhisperKit.loadModels` requires before it will run.
    /// Borrowed knowledge: this mirrors the three `detectModelURL` calls there, and
    /// `testRequiredBundlesAppearInAFetchedModel` is what notices them going stale.
    static let requiredBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    /// Checked per file rather than per directory, because the Hub downloader
    /// creates a bundle directory only immediately before moving the first file
    /// into it: an interrupted download leaves directories without contents, so a
    /// present directory proves nothing while a file at its final path is whole.
    static let requiredFiles = ["coremldata.bin", "model.mil", "weights/weight.bin"]

    /// The root WhisperKit's own downloader writes into. Taken from
    /// `HubApiWrapper`, the API published for exactly this ("callers outside
    /// ArgmaxCore have no dependency on the internal Hub types"), instead of
    /// rebuilding `Documents/huggingface` by hand, so the two cannot drift and the
    /// sandboxed build resolves it inside its container automatically.
    static var defaultRepoRoot: URL {
        HubApiWrapper.shared.localRepoLocation(HubApiWrapper.Repo(id: repoID, type: .models))
    }

    /// The folder holding a complete copy of `variant`, or nil when anything
    /// required is missing. Pure path and existence checks, never the network.
    ///
    /// "Complete" means the CoreML bundles, not everything a load needs. The tokenizer
    /// lives in a separate `models/openai/whisper-*` folder that `WhisperKit.init`
    /// resolves on its own and fetches from the Hub when it is absent, so a model
    /// folder copied in by hand without that cache still fails offline, and the
    /// warning will blame the local model. Both normally arrive together, because the
    /// same download writes them.
    ///
    /// Deliberately stricter than the library in two ways, both of which only ever
    /// cost a download that would have happened anyway. The variant is an exact
    /// folder name, where WhisperKit's downloader matches the glob `*<variant>/*`
    /// and can select a neighbour. And only `.mlmodelc` counts, where
    /// `ModelUtilities.detectModelURL` also accepts `.mlpackage`; the six variants
    /// this app offers ship compiled, and a hypothetical `.mlpackage` copy would
    /// download rather than load wrongly.
    static func locate(variant: String, in repoRoot: URL) -> URL? {
        let folder = repoRoot.appendingPathComponent(variant, isDirectory: true)
        for bundle in requiredBundles {
            let bundleURL = folder.appendingPathComponent("\(bundle).mlmodelc", isDirectory: true)
            for file in requiredFiles {
                guard FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(file).path) else {
                    // Logged because rejecting a folder that is actually there is
                    // the failure mode of stale borrowed names, and it would
                    // otherwise be silent: every load would quietly go back to the
                    // download and reintroduce issue #736 offline. Names only, no
                    // path, which would carry the account name.
                    if FileManager.default.fileExists(atPath: folder.path) {
                        logger.warning(
                            "Local model \(variant, privacy: .public) rejected: \(bundle, privacy: .public) is missing \(file, privacy: .public)",
                        )
                    }
                    return nil
                }
            }
        }
        return folder
    }
}
