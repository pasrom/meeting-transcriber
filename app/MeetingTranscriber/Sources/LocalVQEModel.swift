// Resolves the LocalVQE AEC model the echo canceller runs against.
//
// The model ships inside the app bundle rather than being downloaded on first
// use: it is 2.9 MB, so a download would buy a consent dialog, an offline
// failure mode and first-run latency for nothing. That is a deliberate
// asymmetry against WhisperKit and FluidAudio, whose ~1 GB of models do
// download, not an inconsistency. `scripts/build_release.sh` fetches it via
// `scripts/fetch-localvqe-model.sh` and installs it into Contents/Resources for
// both build variants, so a plain `swift build` has no model and every path
// here has to tolerate its absence.
import Foundation

enum LocalVQEModel {
    /// Matched by prefix and extension rather than by exact filename, so
    /// `scripts/fetch-localvqe-model.sh` stays the single place the model
    /// identity is pinned. A name restated here would be a second pin with no
    /// way to notice the first one moved: a model bump would edit the shell
    /// pin, leave every unit test green, and silently resolve to `.absent` in
    /// the shipped app. The identity stays visible in the bundle listing,
    /// which is what the name was for.
    static let resourcePrefix = "localvqe-"
    static let resourceExtension = "gguf"

    /// Points the app at a different .gguf without a rebuild. Used by the
    /// bundle check and by measurement runs that compare model variants.
    static let overrideEnvironmentKey = "MEETINGTRANSCRIBER_LOCALVQE_MODEL"

    enum Resolution: Equatable {
        /// A model to load, from the override or from the bundle. Which of the
        /// two is not a distinction any caller can act on, and the path says
        /// it anyway.
        case found(path: String)
        /// The override was set but names nothing. Deliberately NOT a fallback
        /// to the bundled model: someone asked for one specific model, and
        /// silently running a different one would make every measurement taken
        /// afterwards wrong in a way nothing reports.
        case overrideMissing(path: String)
        /// No override, no bundled model. The normal state of a `swift build`.
        case absent

        var path: String? {
            if case let .found(path) = self { return path }
            return nil
        }
    }

    static func resolve(
        override: String?,
        bundledPath: String?,
        fileExists: (String) -> Bool,
    ) -> Resolution {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return fileExists(override) ? .found(path: override) : .overrideMissing(path: override)
        }
        // The bundle can name a resource that is not on disk (a stripped or
        // half-assembled bundle), so the existence check is not redundant with
        // the lookup returning non-nil.
        guard let bundledPath, fileExists(bundledPath) else { return .absent }
        return .found(path: bundledPath)
    }

    static func resolve() -> Resolution {
        resolve(
            override: ProcessInfo.processInfo.environment[overrideEnvironmentKey],
            bundledPath: bundledModelPath(in: .main),
            fileExists: FileManager.default.fileExists(atPath:),
        )
    }

    /// `min()` so a bundle that somehow carries two models resolves the same
    /// way on every launch rather than depending on directory order.
    static func bundledModelPath(in bundle: Bundle) -> String? {
        bundle.urls(forResourcesWithExtension: resourceExtension, subdirectory: nil)?
            .filter { $0.lastPathComponent.hasPrefix(resourcePrefix) }
            .map(\.path)
            .min()
    }
}
