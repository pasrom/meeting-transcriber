import Foundation

/// One recording the pipeline moved into the output folder itself, as the
/// retention cleaner knows it.
///
/// Written when the audio is relocated, not when the job finishes, so a quit
/// between the two still leaves a record of whose files these are. Only the
/// pipeline's own relocation writes one, which is what keeps imports, record-only
/// output and everything recorded before this existed out of reach: the cleaner
/// deletes only what is listed here and never looks at the folder itself.
struct RetainedRecording: Codable, Equatable, Sendable {
    let jobID: UUID
    /// The relocated tracks (`_mix.wav`, `_app.wav`, `_mic.wav`, whichever the
    /// job had). Updated when a later rename moves them.
    var paths: [URL]
    /// The output folder the files were moved under, not its `recordings`
    /// child. Whether it exists is what tells an unplugged drive from files the
    /// user deleted.
    let root: URL
    /// What the timestamp in the file name says: the meeting start for a live
    /// recording. The retention days count from here.
    let recordedAt: Date
    /// When the job finished with its outputs written. Nil until then, and for
    /// a job that failed, which keeps its audio.
    var eligibleAt: Date?
    /// The output that made the entry eligible: the protocol, or with no
    /// protocol provider the transcript.
    var outputPath: URL?
    /// The protocol went to Notion and its local copy was removed on purpose
    /// (export set to replace the local Markdown). The page is the output
    /// then, and a missing `outputPath` does not mean the user deleted it.
    var outputExported = false

    init(jobID: UUID, paths: [URL], root: URL, recordedAt: Date, eligibleAt: Date? = nil, outputPath: URL? = nil) {
        self.jobID = jobID
        self.paths = paths
        self.root = root
        self.recordedAt = recordedAt
        self.eligibleAt = eligibleAt
        self.outputPath = outputPath
    }

    private enum CodingKeys: String, CodingKey {
        case jobID, paths, root, recordedAt, eligibleAt, outputPath, outputExported
    }

    /// `outputExported` decodes as absent-means-false, so an entry written
    /// before it existed still reads.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(UUID.self, forKey: .jobID)
        paths = try container.decode([URL].self, forKey: .paths)
        root = try container.decode(URL.self, forKey: .root)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        eligibleAt = try container.decodeIfPresent(Date.self, forKey: .eligibleAt)
        outputPath = try container.decodeIfPresent(URL.self, forKey: .outputPath)
        outputExported = try container.decodeIfPresent(Bool.self, forKey: .outputExported) ?? false
    }
}

/// The two retention settings, read together on every pass.
struct RecordingRetentionSettings: Equatable {
    let enabled: Bool
    /// Days after the recording date; 0 deletes as soon as the outputs exist.
    let days: Int
}

/// What the cleaner does with one entry on one pass.
enum RecordingRetentionDecision: Equatable {
    /// Delete these files, then forget the entry.
    case delete([URL])
    case keep(KeepReason)
    /// Forget the entry without deleting anything.
    case drop(DropReason)

    /// The raw value is the name the pass's log line uses.
    enum KeepReason: String, CaseIterable {
        case disabled
        case awaitingOutputs
        case withinRetention
        case inUse
        case rootUnreachable
        case outputMissing
        case outsideRoot
    }

    enum DropReason: Equatable {
        case filesGone
    }
}

/// What one pass decided, counted per outcome, for the line it logs.
///
/// Counts and reason names only: a path or file name carries the meeting
/// title. Without it a pass that keeps everything leaves no trace, so a log
/// cannot tell it from a pass that never ran.
struct RecordingRetentionPassSummary {
    private(set) var entries = 0
    private(set) var due = 0
    private(set) var dueFiles = 0
    private(set) var dropped = 0
    private(set) var kept: [RecordingRetentionDecision.KeepReason: Int] = [:]
    /// Set after the deletes. Below `dueFiles` when they stopped short.
    var deletedFiles = 0

    mutating func count(_ decision: RecordingRetentionDecision) {
        entries += 1
        switch decision {
        case let .delete(urls):
            due += 1
            dueFiles += urls.count

        case .drop: dropped += 1

        case let .keep(reason): kept[reason, default: 0] += 1
        }
    }

    /// Name-value pairs, so a count of one reads as well as any other.
    var logLine: String {
        let reasons = RecordingRetentionDecision.KeepReason.allCases.compactMap { reason in
            kept[reason].map { "\(reason.rawValue) \($0)" }
        }
        let line = "Retention pass: entries \(entries), due \(due) (files \(dueFiles)), "
            + "deleted files \(deletedFiles), dropped \(dropped), kept \(kept.values.reduce(0, +))"
        return reasons.isEmpty ? line : "\(line) (\(reasons.joined(separator: ", ")))"
    }
}

/// Decides per registry entry whether its audio is due for deletion.
///
/// Pure: the clock, the settings, the paths running jobs hold and the file
/// system are all passed in, so the order of the checks below is the whole
/// policy and each step can be pinned on its own.
enum RecordingRetentionPolicy {
    /// What the decision may ask about the world besides the entry itself.
    struct Environment {
        /// Standardized paths a job that is not finished holds.
        let excludedPaths: Set<String>
        /// The output folder a live security scope is held on, or nil when
        /// none is.
        let scopedRoot: URL?
        let fileExists: (URL) -> Bool
        /// Whether the file is a regular file with content.
        let hasContent: (URL) -> Bool
        /// The path with symlinks resolved.
        let resolve: (URL) -> URL
        /// Whether a folder's contents can be read, so that a file missing
        /// from it is really gone rather than out of sight.
        let canList: (URL) -> Bool

        /// The file system as it is.
        static func live(excludedPaths: Set<String>, scopedRoot: URL?) -> Self {
            Self(
                excludedPaths: excludedPaths, scopedRoot: scopedRoot,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                hasContent: { RecordingRetentionPolicy.isWrittenFile($0) },
                resolve: { $0.resolvingSymlinksInPath() },
                canList: { FileManager.default.isReadableFile(atPath: $0.path) },
            )
        }
    }

    static func decide(
        _ entry: RetainedRecording,
        now: Date,
        settings: RecordingRetentionSettings,
        environment: Environment,
    ) -> RecordingRetentionDecision {
        let fileExists = environment.fileExists
        guard settings.enabled else { return .keep(.disabled) }
        // Before any file check: a job still running holds its paths, and if
        // its files are briefly not visible its entry must not be dropped,
        // since nothing would register it again.
        guard !isInUse(entry, excludedPaths: environment.excludedPaths) else { return .keep(.inUse) }
        // Under a live scope on one output folder, an entry recorded under
        // another is out of reach: its folder's grant is not held.
        if let scopedRoot = environment.scopedRoot, pathKey(scopedRoot) != pathKey(entry.root) {
            return .keep(.rootUnreachable)
        }
        // Checked before the files, because a missing root makes every file
        // look missing, and dropping the entry then would leave the files on
        // the drive for good once it is mounted again.
        guard fileExists(entry.root) else { return .keep(.rootUnreachable) }
        let inside = entry.paths.filter { isInRecordingsFolder($0, of: entry.root, in: environment) }
        let present = inside.filter(fileExists)
        // A path outside the folder is never deleted and never forgotten.
        // Checked before eligibility and the period: an entry whose audio is
        // all gone has nothing left to keep, eligible or not, so it is dropped
        // rather than kept for good.
        guard !present.isEmpty else {
            if inside.count < entry.paths.count { return .keep(.outsideRoot) }
            // Missing only counts as gone where the folder can be listed: with
            // no scope held, the sandbox can show the root and hide its files.
            let recordings = entry.root.appendingPathComponent("recordings", isDirectory: true)
            return environment.canList(recordings) ? .drop(.filesGone) : .keep(.rootUnreachable)
        }
        guard entry.eligibleAt != nil else { return .keep(.awaitingOutputs) }
        guard isDue(entry, now: now, settings: settings) else { return .keep(.withinRetention) }
        // The output has to be written now, not only when the job finished: a
        // protocol or transcript deleted or emptied since leaves the audio the
        // only copy. A protocol exported to Notion in place of the local copy
        // is the exception: that copy was removed on purpose.
        guard entry.outputExported || entry.outputPath.map(environment.hasContent) == true else {
            return .keep(.outputMissing)
        }
        return .delete(present)
    }

    /// Whether `entry` is switched on, eligible and past the period. Also
    /// asked again right before each delete, since a pass can outlast a
    /// change of the settings.
    static func isDue(_ entry: RetainedRecording, now: Date, settings: RecordingRetentionSettings) -> Bool {
        guard settings.enabled, entry.eligibleAt != nil else { return false }
        return now >= entry.recordedAt.addingTimeInterval(TimeInterval(max(0, settings.days)) * 86400)
    }

    /// Whether any track of `entry` is held by a job that is not finished.
    /// Any one track, not just the mix: a run reads all three.
    static func isInUse(_ entry: RetainedRecording, excludedPaths: Set<String>) -> Bool {
        entry.paths.contains { excludedPaths.contains(pathKey($0)) }
    }

    /// Whether `url` sits directly in `root`'s `recordings` folder, both as
    /// written and with symlinks resolved, so neither a `..` in the path nor a
    /// link pointing elsewhere can make the cleaner delete outside it.
    ///
    /// The folder the file is in is resolved, not the file: a file that is
    /// gone cannot be resolved, and under an output folder reached through a
    /// symlink it would then read as outside. A file that exists is also
    /// resolved itself, which catches a file that is a link to elsewhere.
    static func isInRecordingsFolder(_ url: URL, of root: URL, in environment: Environment) -> Bool {
        let folder = pathKey(environment.resolve(root.appendingPathComponent("recordings", isDirectory: true)))
        let containing = url.deletingLastPathComponent()
        guard pathKey(containing) == pathKey(root.appendingPathComponent("recordings", isDirectory: true)),
              pathKey(environment.resolve(containing)) == folder
        else { return false }
        return !environment.fileExists(url)
            || pathKey(environment.resolve(url).deletingLastPathComponent()) == folder
    }

    /// Whether `url` is a regular file with content, the bar a protocol or
    /// transcript has to clear to count as written. Not followed through a
    /// symlink.
    static func isWrittenFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular && (attributes[.size] as? Int ?? 0) > 0
    }

    /// Whether `url` names a regular file or nothing at all, so a delete
    /// there can only remove one file. A folder would be removed with its
    /// contents, and a link is not the recording. Not followed through a
    /// symlink.
    static func isRegularFileOrGone(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return !FileManager.default.fileExists(atPath: url.path)
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    /// The form paths are compared in, matching the in-flight claims and the
    /// processed-recordings ledger.
    static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
