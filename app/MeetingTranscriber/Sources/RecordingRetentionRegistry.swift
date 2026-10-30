import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingRetentionRegistry")

/// File-backed list of the recordings the pipeline relocated into the output
/// folder, the only thing the retention cleaner ever deletes from.
///
/// A list of what the app moved rather than a rule about what a folder holds:
/// the output folder also carries record-only captures, files the user
/// imported or re-imported, and everything recorded before this existed, and
/// none of those can be told apart from the pipeline's own audio by name or
/// place alone. An entry is written for every relocation, whether retention is
/// switched on or not, so switching it on later covers recordings made while it
/// was off. It is never seeded from the folder, so audio from before this
/// feature stays untouched.
///
/// One JSON file (`retained_recordings.json` in `logDir`), written atomically
/// and owner-only like `ProcessedRecordingsLedger`, since the paths embed the
/// account name and meeting titles. Unlike `TerminalJobStore` it has no cap:
/// dropping an entry would make its files permanent.
@MainActor
final class RecordingRetentionRegistry {
    static let filename = "retained_recordings.json"

    let path: URL
    private(set) var entries: [RetainedRecording]

    init(path: URL) {
        self.path = path
        entries = Self.load(from: path)
    }

    /// Record that the pipeline moved `paths` for `jobID` under `root`. A job
    /// relocated again under the same root (a re-run after a restore) adds to
    /// its entry and keeps the first recording date; under a different root it
    /// starts a second entry, so each entry names the one folder its files are
    /// in. Empty `paths` (nothing was moved) is a no-op.
    func register(jobID: UUID, paths: [URL], root: URL, recordedAt: Date) {
        guard !paths.isEmpty else { return }
        strip(Set(paths.map(RecordingRetentionPolicy.pathKey)), keeping: jobID)
        let rootKey = RecordingRetentionPolicy.pathKey(root)
        if let index = entries.firstIndex(where: { entry in
            entry.jobID == jobID && RecordingRetentionPolicy.pathKey(entry.root) == rootKey
        }) {
            let known = Set(entries[index].paths.map(RecordingRetentionPolicy.pathKey))
            entries[index].paths += paths.filter { !known.contains(RecordingRetentionPolicy.pathKey($0)) }
        } else {
            entries.append(RetainedRecording(
                jobID: jobID, paths: paths, root: root, recordedAt: recordedAt, eligibleAt: nil, outputPath: nil,
            ))
        }
        save()
    }

    /// Record that the job finished with `output` written. Keeps the first
    /// date if called again; a job the registry does not know is a no-op.
    func markEligible(jobID: UUID, output: URL, at date: Date) {
        var changed = false
        for index in entries.indices where entries[index].jobID == jobID && entries[index].eligibleAt == nil {
            entries[index].eligibleAt = date
            entries[index].outputPath = output
            changed = true
        }
        if changed { save() }
    }

    /// Record that the job's protocol now lives in Notion: the export replaced
    /// the local Markdown and removed it. From here a missing local file is
    /// expected and no longer keeps the audio.
    func markOutputExported(jobID: UUID) {
        var changed = false
        for index in entries.indices where entries[index].jobID == jobID && !entries[index].outputExported {
            entries[index].outputExported = true
            changed = true
        }
        if changed { save() }
    }

    /// Follow files a rename moved, so the entry keeps naming where they are.
    /// Without it the cleaner would find the old names gone, drop the entry
    /// and leave the renamed audio in place for good.
    func repoint(jobID: UUID, moves: [(from: URL, to: URL)]) {
        let targets = Dictionary(moves.map { (RecordingRetentionPolicy.pathKey($0.from), $0.to) }) { _, last in last }
        var moved: [URL] = []
        var changed = false
        for index in entries.indices where entries[index].jobID == jobID {
            let repointed = entries[index].paths.map { targets[RecordingRetentionPolicy.pathKey($0)] ?? $0 }
            let output = entries[index].outputPath.map { targets[RecordingRetentionPolicy.pathKey($0)] ?? $0 }
            guard repointed != entries[index].paths || output != entries[index].outputPath else { continue }
            entries[index].paths = repointed
            entries[index].outputPath = output
            moved += repointed
            changed = true
        }
        guard changed else { return }
        strip(Set(moved.map(RecordingRetentionPolicy.pathKey)), keeping: jobID)
        save()
    }

    /// Forget deleted files, for the job the deletion was decided for only. A
    /// newer recording that took a path over in the meantime keeps it.
    func forget(_ paths: [URL], of jobID: UUID) {
        guard !paths.isEmpty else { return }
        let keys = Set(paths.map(RecordingRetentionPolicy.pathKey))
        for index in entries.indices where entries[index].jobID == jobID {
            entries[index].paths.removeAll { keys.contains(RecordingRetentionPolicy.pathKey($0)) }
        }
        pruneEmpty()
        save()
    }

    /// Forget these entries, whose files are all gone. By entry, not by job: a
    /// job's entry under another root may still name files that exist.
    func remove(_ dropped: [RetainedRecording]) {
        guard !dropped.isEmpty else { return }
        entries.removeAll { entry in dropped.contains { $0.jobID == entry.jobID && $0.root == entry.root } }
        save()
    }

    /// The entry of `jobID` that still lists `path`, or nil once it does not:
    /// the decision to delete it no longer stands.
    func entry(listing path: URL, for jobID: UUID) -> RetainedRecording? {
        let key = RecordingRetentionPolicy.pathKey(path)
        return entries.first { $0.jobID == jobID && $0.paths.contains { RecordingRetentionPolicy.pathKey($0) == key } }
    }

    /// Whether the entries in memory are the ones on disk. False after a
    /// failed write until one succeeds; the cleaner deletes nothing while it
    /// is false, because after a crash the older list on disk could name a
    /// path a newer recording took over.
    private(set) var isPersisted = true

    /// Write again if the last write failed. True when memory and disk agree.
    func persist() -> Bool {
        if !isPersisted { save() }
        return isPersisted
    }

    /// Take `keys` away from every entry but `jobID`'s, dropping an entry left
    /// with none. For a path a newer move took over: a path belongs to whoever moved a file there last. A move onto a
    /// taken name replaced the older file, and a name can come free and be
    /// taken again once a user deletes an older meeting's audio and protocol by
    /// hand. Left listed twice, the older entry would delete the newer
    /// meeting's audio on its own, earlier schedule.
    private func strip(_ keys: Set<String>, keeping jobID: UUID) {
        for index in entries.indices where entries[index].jobID != jobID {
            entries[index].paths.removeAll { keys.contains(RecordingRetentionPolicy.pathKey($0)) }
        }
        pruneEmpty()
    }

    private func pruneEmpty() {
        entries.removeAll { $0.paths.isEmpty }
    }

    // MARK: - Persistence

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try JSONEncoder().encode(entries).write(to: path, options: .atomic)
            try? FileManager.default.restrictToOwner(path)
            isPersisted = true
        } catch {
            isPersisted = false
            logger.error("Failed to write retained recordings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Empty on a missing or unreadable file. An unreadable one (it cannot be
    /// read at all, or does not decode) is moved aside to `<name>.unreadable`
    /// first, so the next write does not destroy the entries it held: a list
    /// written by a newer build, read by an older one, can still be put back by
    /// hand. Until then its files only lose the chance to be deleted; they stay
    /// where they are.
    private static func load(from path: URL) -> [RetainedRecording] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        do {
            return try JSONDecoder().decode([RetainedRecording].self, from: Data(contentsOf: path))
        } catch {
            logger.error("Failed to read retained recordings: \(error.localizedDescription, privacy: .public)")
            let aside = path.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: path, to: aside)
            return []
        }
    }
}
