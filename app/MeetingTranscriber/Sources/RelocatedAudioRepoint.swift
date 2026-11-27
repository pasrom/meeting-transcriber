import Foundation

/// Where a restored job's audio is when its snapshot still names staging
/// paths that stage 3 has already emptied (the snapshot write lags the move;
/// see "The snapshot can lag the move" in `docs/architecture/pipeline.md`).
enum RelocatedAudioRepoint {
    /// The job's paths with every repointable slot pointed at the output
    /// folder, or nil when no slot needs it.
    ///
    /// A slot is pointed at `<recordingsDir>/<stem><suffix>` only when its path
    /// is in `stagingDir` (a file the app made, never an import or a file
    /// already in the output folder), that path is gone, and the file there
    /// exists. The stem is the one stage 3 moves the job's audio under: the
    /// job's `namingSlug`, which the run records before the move, else the
    /// stem rebuilt from the job (its start time renders in the current time
    /// zone, so after a zone change only the recorded one matches). Only a
    /// stem that ends in the job's short ID is tried: a `namingSlug` an
    /// AI-title rename set can be the bare title, and a rename only follows
    /// the move, so no file under it belongs to a slot still naming staging.
    /// So a job is never pointed at another job's recording, even one that
    /// shared its staging path.
    static func plan(
        for job: PipelineJob, stagingDir: URL, recordingsDir: URL, exists: (URL) -> Bool,
    ) -> RelocatedAudioPaths? {
        // The staging folder as given and with its links resolved, so a
        // staging folder given through a link still matches the slots written
        // under the folder it points to. A slot's folder is compared with both
        // as written, not resolved itself: resolving reads every folder of the
        // path, and for a slot in the output folder that is the output
        // folder, possibly a network mount, read for nothing. So a slot
        // written through a link to a staging folder given unresolved is not
        // matched; today the recorder and the queue use the same staging path.
        let staging: Set<String> = [stagingDir.standardizedFileURL.path, stagingDir.resolvingSymlinksInPath().path]
        // Built once, and only for a job with a staging path that is gone.
        lazy var stems = [job.namingSlug, job.artifactStem].compactMap(\.self)
            .filter { $0.hasSuffix(job.shortID) }
        var changed = false
        func repoint(_ path: URL?, _ suffix: String) -> URL? {
            // Local checks first. A slot already in the output folder (a
            // held finished job, one waiting for names) stops at the folder
            // compare, and in the usual restore every staging file is still
            // there: the output folder is only read for a gone staging file.
            guard let path, staging.contains(path.deletingLastPathComponent().standardizedFileURL.path),
                  !exists(path),
                  AudioPersistencePolicy.action(source: path, stagingDir: stagingDir, destinationDir: recordingsDir) == .move
            else { return path }
            guard let destination = stems.lazy
                .map({ recordingsDir.appendingPathComponent($0 + suffix) })
                .first(where: exists) else { return path }
            changed = true
            return destination
        }
        let paths = RelocatedAudioPaths(
            mix: repoint(job.mixPath, RecordingFileSuffix.mix),
            app: repoint(job.appPath, RecordingFileSuffix.app),
            mic: repoint(job.micPath, RecordingFileSuffix.mic),
        )
        return changed ? paths : nil
    }
}
