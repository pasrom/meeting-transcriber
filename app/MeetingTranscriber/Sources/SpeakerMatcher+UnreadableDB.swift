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
        /// A JSON array of which only some entries are usable: `dropped`
        /// entries did not decode (see `decodeSalvaging`). Reads use
        /// `kept`; `mutateDB` copies the file aside before saving `kept`, so
        /// the dropped entries stay recoverable from that copy.
        case salvaged(kept: [StoredSpeaker], dropped: Int)
        /// No file yet (fresh install), or one holding nothing but
        /// whitespace: nothing to lose, start empty.
        case missing
        /// The file was read but is not a JSON array, twice (see
        /// `settleBeforeReread`). Nothing in it can be salvaged and retrying
        /// will not help, so `mutateDB` copies it aside and replaces it.
        case undecodable(any Error)
        /// The file exists but reading it failed (permissions, I/O, a file
        /// not yet materialised). It may be intact, so it stays where it is.
        case unreadable(any Error)

        /// What a reader can use: the decoded or salvaged entries, else none.
        var usableSpeakers: [StoredSpeaker] {
            switch self {
            case let .loaded(speakers), let .salvaged(speakers, _): speakers
            case .missing, .undecodable, .unreadable: []
            }
        }
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
        /// Where an undecodable or partly undecodable DB was copied before this
        /// change was saved. The block then ran against only the entries that
        /// could be salvaged (none for a file that did not decode at all), so
        /// a "not found" from it says nothing about the names the user knows,
        /// and every cached view of the DB is stale.
        var replacedCorruptDB: URL?

        var saved: Bool {
            persistence == .saved
        }

        /// Where the DB was copied aside, for an edit to report instead of its
        /// own result, unless the edit `found` its target among the salvaged
        /// entries; that result already tells callers to refresh.
        func resetUnlessFound(_ found: Bool) -> URL? {
            found ? nil : replacedCorruptDB
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
        /// Undecodable (or an array with nothing usable); copied to this path
        /// unchanged and replaced by a fresh DB.
        case copiedAside(URL)
        /// A JSON array with some unusable entries; copied to this path
        /// unchanged and replaced by a DB holding the `kept` entries (at
        /// least one). The `dropped` ones are only in the copy.
        case salvaged(copiedTo: URL, kept: Int, dropped: Int)
        /// Left in place and nothing written, so the change was not saved:
        /// unreadable, or damaged and impossible to copy aside.
        case leftInPlace
        /// Writing failed; the DB on disk is unchanged. `copiedTo` is the
        /// copy of a damaged DB, made for this attempt or reused from an
        /// earlier one with the same bytes; it stays.
        case saveFailed(copiedTo: URL?)
    }

    /// How a file that has to be copied aside before a write is damaged.
    enum Damage: Equatable {
        /// Not a JSON array, or one with nothing usable in it.
        case undecodable
        /// A JSON array with some unusable entries.
        case salvaged(kept: Int, dropped: Int)

        var label: String {
            switch self {
            case .undecodable: "undecodable"
            case .salvaged: "partly undecodable"
            }
        }

        /// What to report once the copy is at `url` and the write succeeded.
        func problem(copiedTo url: URL) -> DBProblem {
            switch self {
            case .undecodable: .copiedAside(url)
            case let .salvaged(kept, dropped): .salvaged(copiedTo: url, kept: kept, dropped: dropped)
            }
        }
    }

    /// What `mutateDB` does with what it read: the speakers its block starts
    /// from, whether it may write at all, and how the file is damaged when it
    /// must be copied aside first.
    struct WritePlan {
        var stored: [StoredSpeaker] = []
        var writable = true
        var damage: Damage?
    }

    static func writePlan(for outcome: ReadOutcome) -> WritePlan {
        var plan = WritePlan(stored: outcome.usableSpeakers)
        switch outcome {
        case .loaded, .missing:
            break

        case let .undecodable(error):
            logger.error("Speaker DB undecodable: \(error.localizedDescription, privacy: .public)")
            plan.damage = .undecodable

        // Nothing usable is the same loss as an undecodable file.
        case let .salvaged(kept, _) where kept.isEmpty:
            logger.error("Speaker DB holds no usable entry")
            plan.damage = .undecodable

        case let .salvaged(kept, dropped):
            logger.error("Speaker DB partly undecodable: keeping \(kept.count), dropping \(dropped)")
            plan.damage = .salvaged(kept: kept.count, dropped: dropped)

        case let .unreadable(error):
            logger.error("Speaker DB unreadable, not writing: \(error.localizedDescription, privacy: .public)")
            plan.writable = false
        }
        return plan
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
            let entries = try decodeSalvaging(data)
            return entries.dropped == 0 ? .loaded(entries.kept) : .salvaged(kept: entries.kept, dropped: entries.dropped)
        } catch {
            return .undecodable(error)
        }
    }

    /// Decode a DB entry by entry, keeping each one `StoredSpeaker` decodes.
    /// Its decoder is the one rule for a usable entry: it rejects a wrong
    /// type, a missing name, and a value no `Float` can hold (plain JSON has
    /// no NaN token, so that is how a non-finite value arrives). Throws only
    /// when `data` is not a JSON array at all, which leaves nothing to
    /// salvage. Pure, so the per-entry rules are testable without a file.
    static func decodeSalvaging(_ data: Data) throws -> (kept: [StoredSpeaker], dropped: Int) {
        let entries = try JSONDecoder().decode([SalvagedEntry].self, from: data)
        let kept = entries.compactMap(\.speaker)
        return (kept, entries.count - kept.count)
    }

    /// One array element that decodes to nil instead of failing the whole
    /// array. Its own decode always succeeds, so the array decode moves on to
    /// the next element.
    private struct SalvagedEntry: Decodable {
        let speaker: StoredSpeaker?

        init(from decoder: any Decoder) {
            speaker = try? StoredSpeaker(from: decoder)
        }
    }

    private static let jsonWhitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

    /// How long `mutateDB` waits before reading an undecodable DB a second
    /// time. A sync tool (the fleet setups use Syncthing) can be caught
    /// mid-write; quarantining that file would replace it with a near-empty DB
    /// that then syncs out to every other machine.
    static let rereadDelay: TimeInterval = 0.3

    /// Copy a damaged DB to `speakers.json.corrupt-<timestamp>` next to it,
    /// unchanged and owner-only like the DB itself. The original stays in
    /// place until the atomic replace in `writeDB` swaps the new file in, so
    /// a failed write leaves it untouched and a reader never finds the path
    /// empty. Returns the copy's path, or nil when copying failed (the caller
    /// must then not write). Call with `dbLock` held.
    static func quarantineDamagedDB(at path: URL, damage: Damage) -> URL? {
        let kind = damage.label
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        // Copy under a name only this call uses, then move it to its final
        // name: a failed copy then removes nothing but its own file, never
        // the copy another process on the same DB made in the same second.
        let partial = dir.appendingPathComponent(".\(path.lastPathComponent).quarantine-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: path, to: partial)
            try fm.restrictToOwner(partial)
        } catch {
            try? fm.removeItem(at: partial)
            logger.error("Could not copy \(kind, privacy: .public) speaker DB aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let base = "\(path.lastPathComponent).corrupt-\(quarantineStampFormatter.string(from: Date()))"
        // `moveItem` refuses an existing name, so two quarantines within the
        // same second keep both copies.
        for name in [base, "\(base)-\(UUID().uuidString.prefix(8))"] {
            let target = dir.appendingPathComponent(name)
            if (try? fm.moveItem(at: partial, to: target)) != nil {
                logger.error("Copied \(kind, privacy: .public) speaker DB to \(name, privacy: .public)")
                return target
            }
        }
        try? fm.removeItem(at: partial)
        logger.error("Could not name the \(kind, privacy: .public) speaker DB copy")
        return nil
    }

    /// The copy a write that failed for this unchanged file made, when it
    /// still holds exactly the bytes at `path`. Anything else (edited,
    /// truncated, replaced, or a DB rewritten in place with the same
    /// metadata) is not a copy of what the next write replaces, so the
    /// caller makes a fresh one. Restricted again, since the first attempt's
    /// chmod may have failed. Call with `dbLock` held.
    static func existingCopy(after known: DBProblem?, of path: URL) -> URL? {
        guard case let .saveFailed(url?) = known,
              let copy = try? Data(contentsOf: url),
              let original = try? Data(contentsOf: path),
              copy == original else { return nil }
        try? FileManager.default.restrictToOwner(url)
        return url
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
    /// A completed quarantine always does: the original was replaced, so
    /// there is no earlier state it could repeat. A failed save, with or
    /// without a copy, leaves the original in place and is reported once per
    /// state of that file. Call with `dbLock` held; `reports` is guarded by it.
    static func shouldReport(_ problem: DBProblem, at path: URL, reports: inout [URL: ProblemReport]) -> Bool {
        switch problem {
        case .copiedAside, .salvaged:
            reports[path] = nil
            return true

        case .leftInPlace, .saveFailed:
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
        case let .copiedAside(url):
            notifier.notify(
                title: "Voice profiles could not be read",
                body: "The saved voice profiles were damaged. A copy was kept as "
                    + "\(url.lastPathComponent). Speakers need to be named again.",
            )

        case let .salvaged(url, kept, dropped):
            notifier.notify(title: "Some voice profiles could not be read", body: salvageMessage(
                copiedTo: url, kept: kept, dropped: dropped,
            ))

        case .leftInPlace:
            notifier.notify(
                title: "Voice profiles could not be read",
                body: "The saved voice profiles could not be opened or updated, so speaker "
                    + "names are not being saved. They were left unchanged.",
            )

        case let .saveFailed(copiedTo: url?):
            notifier.notify(
                title: "Voice profiles could not be saved",
                body: "The saved voice profiles are damaged. A copy was kept as "
                    + "\(url.lastPathComponent), but the repaired profiles could not be written, "
                    + "so speaker names are not being saved. The profiles were left unchanged.",
            )

        case .saveFailed(copiedTo: nil):
            notifier.notify(
                title: "Voice profiles could not be saved",
                body: "Writing the voice profiles failed, so speaker names are not being saved.",
            )
        }
    }

    /// The body of the `.salvaged` notification: how many profiles were kept,
    /// how many were not, and where the dropped ones can still be found. A
    /// dropped speaker who is named again gets a new profile; the old one is
    /// not merged back, so the text does not promise that nothing changes.
    static func salvageMessage(copiedTo url: URL, kept: Int, dropped: Int) -> String {
        let file = url.lastPathComponent
        return "\(profiles(kept)) \(kept == 1 ? "was" : "were") kept. "
            + "\(profiles(dropped)) could not be read and \(dropped == 1 ? "was" : "were") "
            + "left out, so \(dropped == 1 ? "that speaker is" : "those speakers are") no longer recognised. "
            + "The original file was kept as \(file). A left-out speaker who is named again "
            + "starts a new profile; the old one stays in that file and is not merged."
    }

    private static func profiles(_ count: Int) -> String {
        count == 1 ? "1 voice profile" : "\(count) voice profiles"
    }
}
