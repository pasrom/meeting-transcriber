import Foundation

/// Which recordings a compaction run works on and what it does with each
/// track. Pure: the entries, the held paths, the settings, the clock and every
/// file fact are passed in, so each rule can be pinned on its own.
///
/// Only entries of `RecordingRetentionRegistry` are ever looked at, never a
/// folder's contents: imports, record-only output, recordings from before the
/// registry existed, recordings of cancelled jobs (never registered) and files
/// renamed by hand are out of reach by construction, as for retention.
enum RecordingCompactionPlan {
    /// Which entries a run takes.
    enum Request: Sendable, Equatable {
        /// Entries marked as owed `kind` when their job finished. The
        /// automatic runs (after `.done`, at launch) ask for these.
        case awaiting(CompactionKind)
        // A run over every entry ("Compress Existing Recordings") is a later
        // request kind here; the selection and the per-track sequence are
        // the same.
    }

    /// Why a whole entry is not worked on in this run. None of these clears
    /// the entry's mark: each can change before the next run.
    enum EntrySkip: String, CaseIterable, Sendable {
        /// The request does not cover it (not marked for this kind).
        case notAwaiting
        /// A job that is not done holds one of its paths.
        case inUse
        /// Recorded under another output folder than the one this run works in.
        case otherRoot
        /// Its output folder is not there (an unplugged drive, a deleted folder).
        case rootMissing
        /// Retention deletes it on its next pass.
        case due
    }

    /// One entry to work on: the WAV tracks it lists directly in its root's
    /// `recordings` folder, in the order listed.
    struct Candidate: Equatable {
        let jobID: UUID
        let root: URL
        let tracks: [URL]
    }

    struct Selection: Equatable {
        var candidates: [Candidate] = []
        var skipped: [EntrySkip: Int] = [:]
        /// Listed WAV tracks of candidates that are not directly in the
        /// recordings folder, and so are never touched.
        var outsideFolder = 0
    }

    /// What the selection may ask about the world besides the entries.
    struct World {
        /// The output folder the run works in.
        let outputRoot: URL
        let now: Date
        /// The settings retention acts on, so an entry about to be deleted
        /// is not converted first.
        let retention: RecordingRetentionSettings
        /// The paths unfinished jobs hold, whether the root exists, and the
        /// containment checks, as retention reads them.
        let environment: RecordingRetentionPolicy.Environment
    }

    static func select(_ entries: [RetainedRecording], request: Request, in world: World) -> Selection {
        var selection = Selection()
        for entry in entries {
            if let skip = entrySkip(entry, request: request, in: world) {
                selection.skipped[skip, default: 0] += 1
                continue
            }
            let wavTracks = entry.paths.filter(isWAVTrack)
            let inside = wavTracks.filter { track in
                RecordingRetentionPolicy.isInRecordingsFolder(track, of: entry.root, in: world.environment)
            }
            selection.outsideFolder += wavTracks.count - inside.count
            selection.candidates.append(Candidate(jobID: entry.jobID, root: entry.root, tracks: inside))
        }
        return selection
    }

    /// Checked in this order, the cheapest and the least file-dependent first.
    private static func entrySkip(_ entry: RetainedRecording, request: Request, in world: World) -> EntrySkip? {
        switch request {
        case let .awaiting(kind):
            guard entry.awaiting.contains(kind) else { return .notAwaiting }
        }
        if RecordingRetentionPolicy.isInUse(entry, excludedPaths: world.environment.excludedPaths) { return .inUse }
        if RecordingRetentionPolicy.pathKey(entry.root) != RecordingRetentionPolicy.pathKey(world.outputRoot) {
            return .otherRoot
        }
        if !world.environment.fileExists(entry.root) { return .rootMissing }
        if RecordingRetentionPolicy.isDue(entry, now: world.now, settings: world.retention) { return .due }
        return nil
    }

    /// A track as recorded: `_mix.wav`, `_app.wav` or `_mic.wav`. The
    /// recording sidecar and a track already compressed are not.
    static func isWAVTrack(_ url: URL) -> Bool {
        RecordingFileSuffix.stripSuffix(from: url.lastPathComponent) != nil
    }

    // MARK: - Per track

    /// What the file system says about one listed WAV track and its
    /// compressed name, read off the main actor before anything is written.
    struct TrackFacts: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// A regular file, with what the commit checks again before the
            /// copy takes its place.
            case regular(Stamp)
            /// Not there (`ENOENT`): deleted by hand, or moved by a rename.
            case missing
            /// A folder, a link or anything else that is not the recording.
            case notRegular
            /// Could not be looked at for another reason (a permission
            /// error, a stalled mount): not taken for gone.
            case unreadable
        }

        /// Size and modification time: a source that changed while the copy
        /// was made is not the source the copy was compared with.
        struct Stamp: Equatable, Sendable {
            let size: Int64
            let modified: Date
        }

        var source: Source
        /// The file is in iCloud Drive or another File Provider and its
        /// content is not on this Mac; reading it would download it or fail.
        var evicted = false
        /// Free bytes on the volume, nil when that could not be read.
        var freeBytes: Int64?
        var destinationExists = false
    }

    /// Which file a path names, taken of the partial right after it was
    /// verified and compared again in the commit, so a copy replaced in
    /// between is never given a track name.
    struct FileIdentity: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
    }

    /// Why one track is not converted in this run.
    enum TrackSkip: String, CaseIterable, Sendable {
        case notRegularFile
        case evicted
        case lowSpace
        /// A file the entry does not list holds the compressed name. Never
        /// overwritten: it may be the user's.
        case destinationTaken
        // Outcomes of the attempt itself:
        case unreadable
        case notIntegerPCM
        /// The header's length does not account for the file's size.
        case lengthMismatch
        case mismatch
        case notNativeFLAC
        case syncFailed
        case writeFailed
        /// The recording changed while the copy was made (renamed, taken by
        /// a job, re-recorded, the copy replaced, or the registry could not
        /// be written).
        case recheckFailed
        case cancelled

        /// Whether trying again later cannot help, so the entry's mark may go.
        /// A file that stays what it is (not integer PCM, a header that
        /// disagrees with its size, a link, a copy that does not match) would
        /// fail the same way on every launch. A failed sync is not among
        /// them: an `open` or `fsync` error can pass.
        var isPermanent: Bool {
            switch self {
            case .notRegularFile, .destinationTaken, .notIntegerPCM, .lengthMismatch, .mismatch, .notNativeFLAC: true
            case .evicted, .lowSpace, .unreadable, .syncFailed, .writeFailed, .recheckFailed, .cancelled: false
            }
        }

        init(_ failure: KeptRecordingCompressor.Failure) {
            switch failure {
            case .notIntegerPCM: self = .notIntegerPCM
            case .lengthDisagreesWithFileSize: self = .lengthMismatch
            case .mismatch: self = .mismatch
            case .notNativeFLAC: self = .notNativeFLAC
            case .syncFailed: self = .syncFailed
            }
        }
    }

    enum TrackAction: Equatable {
        /// Make the copy and commit it.
        case encode
        /// A run cut off after the rename left both listed: check the copy
        /// against the source, then remove the source.
        case resume
        /// The source is gone and its copy is listed: forget the source.
        case forgetSource
        /// Nothing to do with a source that is gone and has no listed copy.
        case nothingToDo
        case skip(TrackSkip)
    }

    /// Room the copy needs beyond the size of its source: a FLAC copy of
    /// noise can come out a little larger than its WAV.
    static let spaceMargin: Int64 = 64 * 1024 * 1024

    static func action(for facts: TrackFacts, destinationListed: Bool) -> TrackAction {
        switch facts.source {
        case .missing:
            return destinationListed && facts.destinationExists ? .forgetSource : .nothingToDo

        case .notRegular:
            return .skip(.notRegularFile)

        case .unreadable:
            return .skip(.unreadable)

        case let .regular(stamp):
            if facts.evicted { return .skip(.evicted) }
            if facts.destinationExists {
                return destinationListed ? .resume : .skip(.destinationTaken)
            }
            if let free = facts.freeBytes, free < stamp.size + spaceMargin { return .skip(.lowSpace) }
            return .encode
        }
    }
}

/// What one compaction run did, for the line it logs and for `/state`.
/// Counts and reason names only: a path or file name carries the meeting title.
struct RecordingCompactionSummary: Equatable {
    var entries = 0
    var compressed = 0
    /// Copies a cut-off run had committed, checked and finished now.
    var resumed = 0
    /// Listed WAVs a cut-off run had removed but not yet forgotten.
    var forgotten = 0
    var marksCleared = 0
    var sweptPartials = 0
    var outsideFolder = 0
    var registryNotSaved = false
    var skippedEntries: [RecordingCompactionPlan.EntrySkip: Int] = [:]
    var skippedTracks: [RecordingCompactionPlan.TrackSkip: Int] = [:]

    var logLine: String {
        guard !registryNotSaved else { return "Compaction run: registry not saved, nothing done" }
        let entrySkips = RecordingCompactionPlan.EntrySkip.allCases.compactMap { reason in
            skippedEntries[reason].map { "\(reason.rawValue) \($0)" }
        }
        let trackSkips = RecordingCompactionPlan.TrackSkip.allCases.compactMap { reason in
            skippedTracks[reason].map { "\(reason.rawValue) \($0)" }
        }
        var line = "Compaction run: entries \(entries), compressed \(compressed), resumed \(resumed), "
            + "forgotten \(forgotten), marks cleared \(marksCleared), swept partials \(sweptPartials)"
        if outsideFolder > 0 { line += ", outside folder \(outsideFolder)" }
        if !entrySkips.isEmpty { line += ", entries skipped (\(entrySkips.joined(separator: ", ")))" }
        if !trackSkips.isEmpty { line += ", tracks skipped (\(trackSkips.joined(separator: ", ")))" }
        return line
    }
}
