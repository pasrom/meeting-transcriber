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
/// user hand it to us". `DualSourceRecorder` writes into the staging directory,
/// so anything from elsewhere came from the user, which makes the answer
/// derivable from the path and keeps it out of `PipelineJob` and its four
/// construction sites. A provenance flag on the job would be the more explicit
/// design and is a well-trodden path here (`meetingStartTime`, `usedDiarizerMode`
/// and `autoSkipNaming` were all added to the Codable snapshot as optionals with
/// a legacy-nil fallback); location is preferred only because it is exact today
/// and far smaller. Its known edge: a user who navigates the import panel into
/// the staging directory and picks a file there gets it relocated. That is
/// harmless, since staging is not a folder anyone keeps files in, and it matches
/// the behaviour before this policy existed.
enum AudioPersistencePolicy {
    static func action(source: URL, stagingDir: URL, destinationDir: URL) -> AudioPersistenceAction {
        // Compare paths, not URLs: `deletingLastPathComponent()` yields a
        // directory URL with a trailing slash while the directories are passed in
        // without one, and URL equality is string-based, so every comparison
        // would miss.
        //
        // Symlinks are resolved, unlike the `standardizedFileURL.path` used by
        // the ledger and orphan recovery, because those answer "is this the same
        // file" while this answers "is this file inside that directory" — and a
        // symlinked output or staging directory would otherwise read as a
        // different one, which is exactly how the compounding-rename bug used to
        // start. Resolution only differs from lexical standardization for paths
        // that exist, which a source's parent directory always does.
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
