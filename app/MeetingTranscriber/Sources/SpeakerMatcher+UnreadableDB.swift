import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

/// Telling a missing `speakers.json` apart from one that exists but cannot be
/// used, and reporting whether a change actually reached the disk. The
/// difference decides whether `mutateDB` may write: a missing file starts
/// empty, while a present one holds every enrolled voice and must never be
/// overwritten by a DB that was built without it.
///
/// Everything here takes the DB path as an argument rather than reading the
/// matcher's, so `dbPath` stays private to `SpeakerMatcher`.
extension SpeakerMatcher {
    enum ReadOutcome {
        case loaded([StoredSpeaker])
        /// No file yet (fresh install, or after a quarantine), or one holding
        /// nothing but whitespace: nothing to lose, start empty.
        case missing
        /// The file was read but does not decode, twice (see
        /// `settleBeforeReread`). Retrying will not help, so `mutateDB` moves
        /// it aside.
        case undecodable(any Error)
        /// The file exists but reading it failed (permissions, I/O, a file
        /// not yet materialised). It may be intact, so it stays where it is.
        case unreadable(any Error)
    }

    /// Whether the change a `mutateDB` block made reached `speakers.json`.
    enum Persistence: Equatable {
        case saved
        /// The DB on disk could not be used and was left as it is, so nothing
        /// was written.
        case dbUnavailable
        /// Encoding or writing the DB failed.
        case writeFailed
    }

    /// A `mutateDB` block's result plus whether its change was persisted.
    /// Callers that report success to someone (enrollment, RPC) must look at
    /// `persistence`: the block runs either way.
    struct Mutation<Value> {
        let value: Value
        let persistence: Persistence
        /// Where an undecodable DB was moved before this change was saved
        /// into a fresh one. The block then ran against an empty DB, so a
        /// "not found" from it says nothing about the names the user knows,
        /// and every cached view of the DB is stale.
        var replacedCorruptDB: URL?

        var saved: Bool {
            persistence == .saved
        }
    }

    /// What `updateDB` did with a confirmation.
    struct ConfirmationOutcome: Equatable {
        /// Names whose voice is now on disk. Empty when nothing was saved.
        let stored: [String]
        /// Names left out because their only embedding had a NaN/Inf value,
        /// which FluidAudio emits for a too-short or too-quiet segment.
        let unusableVoice: [String]
        let persistence: Persistence
    }

    /// What went wrong with the DB in a `mutateDB`, passed to `onDBProblem` so
    /// the user learns their voices are not being kept.
    enum DBProblem: Equatable {
        /// Undecodable; moved to this path and replaced by a fresh DB.
        case movedAside(URL)
        /// Left in place and nothing written, so the change was not saved.
        case leftInPlace
        /// Writing failed. `movedAside` is the quarantined copy when the DB
        /// had just been set aside, which is then the only copy left.
        case saveFailed(movedAside: URL?)
    }

    /// Read `speakers.json`, telling "no file" apart from "a file we cannot
    /// use". Only the latter must never be overwritten.
    static func readDB(at path: URL) -> ReadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable(error)
        }
        // A whitespace-only file holds no voices any more than an empty one.
        guard data.contains(where: { !Self.jsonWhitespace.contains($0) }) else { return .missing }
        do {
            return try .loaded(JSONDecoder().decode([StoredSpeaker].self, from: data))
        } catch {
            return .undecodable(error)
        }
    }

    private static let jsonWhitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

    /// How long `mutateDB` waits before reading an undecodable DB a second
    /// time. A sync tool (the fleet setups use Syncthing) can be caught
    /// mid-write; quarantining that file would replace it with a near-empty DB
    /// that then syncs out to every other machine.
    static let rereadDelay: TimeInterval = 0.3

    /// Move an undecodable DB to `speakers.json.corrupt-<timestamp>` next to
    /// it, owner-only like the DB itself. Returns the new path, or nil when
    /// the move failed (the caller must then not write). Call with `dbLock` held.
    static func quarantineUndecodableDB(at path: URL) -> URL? {
        let stamp = quarantineStampFormatter.string(from: Date())
        let base = "\(path.lastPathComponent).corrupt-\(stamp)"
        let dir = path.deletingLastPathComponent()
        var target = dir.appendingPathComponent(base)
        // Two quarantines within the same second must not replace each other.
        if FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8))")
        }
        do {
            try FileManager.default.moveItem(at: path, to: target)
        } catch {
            logger.error("Could not move undecodable speaker DB aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            try FileManager.default.restrictToOwner(target)
        } catch {
            logger.error("Could not restrict quarantined speaker DB: \(error.localizedDescription, privacy: .public)")
        }
        logger.error("Moved undecodable speaker DB to \(target.lastPathComponent, privacy: .public)")
        return target
    }

    private static let quarantineStampFormatter = DateFormatter.filenameStamp("yyyyMMdd-HHmmss")

    /// Write `speakers` to `path` via a temp file and an atomic replace.
    /// Throws when the data did not reach `path`; a failed owner-only chmod
    /// afterwards is logged but does not count, since the voices are on disk.
    static func writeDB(_ speakers: [StoredSpeaker], to path: URL) throws {
        let data = try JSONEncoder().encode(speakers)
        let tmp = path.deletingLastPathComponent().appendingPathComponent("\(path.lastPathComponent).tmp")
        try data.write(to: tmp)
        do {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        // Voice embeddings/centroids are biometric-adjacent — restrict the
        // persisted DB to owner-only. The temp-file rename does not carry a
        // chmod applied pre-rename, so set it on the final path.
        do {
            try FileManager.default.restrictToOwner(path)
        } catch {
            logger.error("Could not restrict speaker DB: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reporting

    /// Which problem was last reported for a DB path, and the state of the
    /// file it was reported for. `mutateDB` runs on every confirmation, so a
    /// DB that stays unusable would otherwise raise the same notification
    /// each time. Same rule as `PermissionsController.handle`: report a
    /// problem once, again only when it changes (here: when the file on disk
    /// changes), and forget it once a save succeeds.
    struct ProblemReport: Equatable {
        let problem: DBProblem
        let file: FileState?
    }

    /// Enough of a file's metadata to tell that it was replaced or rewritten.
    struct FileState: Equatable {
        let size: Int?
        let modified: Date?
        let inode: Int?

        init?(of path: URL) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else { return nil }
            size = attrs[.size] as? Int
            modified = attrs[.modificationDate] as? Date
            inode = attrs[.systemFileNumber] as? Int
        }
    }

    /// Whether `problem` on `path` should reach the user, recording it if so.
    /// A quarantine always does: it moved a file, so there is no earlier state
    /// it could repeat. Call with `dbLock` held; `reports` is guarded by it.
    static func shouldReport(_ problem: DBProblem, at path: URL, reports: inout [URL: ProblemReport]) -> Bool {
        switch problem {
        case .movedAside, .saveFailed(movedAside: .some):
            reports[path] = nil
            return true

        case .leftInPlace, .saveFailed(movedAside: nil):
            let report = ProblemReport(problem: problem, file: FileState(of: path))
            guard reports[path] != report else { return false }
            reports[path] = report
            return true
        }
    }

    /// How production builds matchers: on `dbPath`, reporting DB problems
    /// through the app's injected notifier, which every write path (pipeline,
    /// Settings, RPC) shares, so tests and e2e lanes post nothing real.
    static func factory(dbPath: URL, notifier: any AppNotifying) -> () -> SpeakerMatcher {
        { SpeakerMatcher(dbPath: dbPath) { notifyDBProblem($0, via: notifier) } }
    }

    /// What `factory` reports a DB problem as: a notification is the only
    /// channel that reaches the user from every write path.
    static func notifyDBProblem(_ problem: DBProblem, via notifier: any AppNotifying) {
        switch problem {
        case let .movedAside(url):
            notifier.notify(
                title: "Voice profiles could not be read",
                body: "The saved voice profiles were damaged and have been set aside as "
                    + "\(url.lastPathComponent). Speakers need to be named again.",
            )

        case .leftInPlace:
            notifier.notify(
                title: "Voice profiles could not be read",
                body: "The saved voice profiles could not be opened, so speaker names "
                    + "are not being saved. They were left unchanged.",
            )

        case let .saveFailed(movedAside: url?):
            notifier.notify(
                title: "Voice profiles could not be saved",
                body: "The saved voice profiles were damaged and have been set aside as "
                    + "\(url.lastPathComponent), and the new profiles could not be written. "
                    + "Speaker names are not being saved.",
            )

        case .saveFailed(movedAside: nil):
            notifier.notify(
                title: "Voice profiles could not be saved",
                body: "Writing the voice profiles failed, so speaker names are not being saved.",
            )
        }
    }
}
