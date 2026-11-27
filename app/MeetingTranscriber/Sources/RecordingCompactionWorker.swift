import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingCompaction")

/// The file work of a compaction run, off the main actor. Every step is a
/// closure so a test can block one, fail one, or copy the folder and the
/// registry at the moment it is called; production uses `Steps.live`.
actor RecordingCompactionWorker {
    struct Steps: Sendable {
        /// The facts `RecordingCompactionPlan.action(for:destinationListed:)` decides on.
        var facts: @Sendable (_ source: URL, _ destination: URL) -> RecordingCompactionPlan.TrackFacts
        /// `KeptRecordingCompressor.prepare`: encode, verify, sync into the partial.
        var prepare: @Sendable (_ source: URL, _ partial: URL) async throws -> Void
        /// Which file the verified partial is, taken right after `prepare`.
        var identity: @Sendable (URL) -> RecordingCompactionPlan.FileIdentity?
        /// Check an existing copy against its source (`KeptRecordingCompressor.verify`).
        var verify: @Sendable (_ copy: URL, _ source: URL) throws -> Void
        /// Flush a folder, so a rename in it is on the disk before the file
        /// it stands in for is removed. Best effort.
        var syncFolder: @Sendable (URL) -> Void
        /// Remove one file (`RecordingFileDeleter.unlinkFile`): throws
        /// `CocoaError(.fileNoSuchFile)` when it is already gone.
        var unlink: @Sendable (URL) throws -> Void
        /// Remove leftover partial copies older than the cutoff from a
        /// folder, except the ones named; returns how many went.
        var sweep: @Sendable (_ folder: URL, _ olderThan: Date, _ keeping: Set<String>) -> Int

        static let live = Self(
            facts: RecordingCompaction.liveFacts,
            prepare: { try KeptRecordingCompressor().prepare(source: $0, partial: $1) },
            identity: RecordingCompaction.liveIdentity,
            verify: { try KeptRecordingCompressor().verify($0, matches: $1) },
            syncFolder: { KeptRecordingCompressor.syncFolder($0) },
            unlink: RecordingFileDeleter.unlinkFile,
            sweep: RecordingCompaction.liveSweep,
        )
    }

    private let steps: Steps

    init(steps: Steps = .live) {
        self.steps = steps
    }

    func facts(_ source: URL, _ destination: URL) -> RecordingCompactionPlan.TrackFacts {
        steps.facts(source, destination)
    }

    func prepare(_ source: URL, _ partial: URL) async throws {
        try await steps.prepare(source, partial)
    }

    func identity(_ url: URL) -> RecordingCompactionPlan.FileIdentity? {
        steps.identity(url)
    }

    func verify(_ copy: URL, _ source: URL) throws {
        try steps.verify(copy, source)
    }

    func syncFolder(_ folder: URL) {
        steps.syncFolder(folder)
    }

    /// True when `url` is gone afterwards, also when it already was.
    func remove(_ url: URL) -> Bool {
        do {
            try steps.unlink(url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            // Private: a file-system error names the file, and the file name
            // is the meeting title.
            logger.warning("Compaction could not remove a file: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func sweep(_ folder: URL, olderThan cutoff: Date, keeping: Set<String>) -> Int {
        steps.sweep(folder, cutoff, keeping)
    }
}
