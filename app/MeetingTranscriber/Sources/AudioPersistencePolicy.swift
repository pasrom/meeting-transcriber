import Foundation

/// What to do with a finished job's source audio when persisting its artifacts.
enum AudioPersistenceAction: Equatable {
    /// The app produced this file in its own staging directory, so it is the
    /// app's to relocate into the output folder.
    case move
    /// The user picked this file from their own folder. Leave it alone.
    case leaveInPlace
    /// Already sitting in the destination directory; moving it would only
    /// rename it under a fresh timestamp on every re-import.
    case alreadyAtDestination
}

/// Decides whether a job's source audio may be relocated when the job finishes.
///
/// The distinction the pipeline needs is "did the app make this file, or did the
/// user hand it to us", and that is derivable from where the file lives rather
/// than needing a provenance flag on `PipelineJob` (which would have to be
/// carried through the Codable snapshot and back-filled for jobs persisted by an
/// older build). `DualSourceRecorder` writes into the staging directory, so
/// anything else came from the user.
enum AudioPersistencePolicy {
    static func action(source: URL, stagingDir: URL, destinationDir: URL) -> AudioPersistenceAction {
        // Compare paths, not URLs: `deletingLastPathComponent()` yields a
        // directory URL with a trailing slash while the directories are passed in
        // without one, and URL equality is string-based, so every comparison
        // would miss. Symlinks are resolved because macOS hands out `/var/…`
        // paths for what is really `/private/var/…`.
        func key(_ url: URL) -> String {
            url.resolvingSymlinksInPath().path
        }

        let sourceDir = key(source.deletingLastPathComponent())
        if sourceDir == key(destinationDir) {
            return .alreadyAtDestination
        }
        return sourceDir == key(stagingDir) ? .move : .leaveInPlace
    }
}
