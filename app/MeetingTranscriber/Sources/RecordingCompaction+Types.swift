import Foundation

/// The value types a compaction run is described by, beside the class.
extension RecordingCompaction {
    /// What one run needs from the queue, or the controller, that asks for it.
    struct Context {
        /// Standardized paths a job that is not finished holds, read at
        /// selection and again in every commit turn.
        let excludedPaths: () -> Set<String>
        /// Point a finished job still in memory at the copy of a track it
        /// names, so its paths keep naming files that exist.
        let repointJobAudio: (_ jobID: UUID, _ from: URL, _ to: URL) -> Void
        /// The output folder this run works in. Entries under another one
        /// are skipped, and only its `recordings` folder is swept.
        let outputRoot: URL
        /// The object the run opens its security scope on, for its whole
        /// length; nil when the caller holds none (a folder that needs none).
        let scopeRoot: URL?
        let securityScope: SecurityScopeAccess
    }

    /// Where the run the user asked for is, for Settings: the rows show
    /// progress and Cancel for it only, never for an automatic pass.
    enum RequestedRun: Equatable {
        case idle
        /// Queued behind an automatic pass.
        case waiting
        case running
    }
}
