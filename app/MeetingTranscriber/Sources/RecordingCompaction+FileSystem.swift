import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingCompaction")

/// The live file-system steps of a compaction run and the sweep of leftover
/// partial copies.
extension RecordingCompaction {
    /// The facts of a WAV track and its compressed name, not following links.
    nonisolated static func liveFacts(source: URL, destination: URL) -> RecordingCompactionPlan.TrackFacts {
        var facts = RecordingCompactionPlan.TrackFacts(source: .missing)
        // One `lstat`: the type, the size, the time and the flags. Only
        // `ENOENT` is gone; any other error is no evidence of that.
        var info = stat()
        if lstat(source.path, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFREG {
                facts.source = .regular(stamp(of: info))
                // A File Provider file whose content is not here.
                facts.evicted = info.st_flags & UInt32(SF_DATALESS) != 0
            } else {
                facts.source = .notRegular
            }
        } else if errno != ENOENT {
            facts.source = .unreadable
        }
        // An iCloud Drive item that is not downloaded.
        let values = try? source.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
            facts.evicted = true
        }
        let volume = try? source.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey])
        facts.freeBytes = volume?.volumeAvailableCapacity.map(Int64.init)
        // A link at the name counts as taken too.
        var destinationInfo = stat()
        facts.destinationExists = lstat(destination.path, &destinationInfo) == 0
        return facts
    }

    nonisolated static func liveStamp(_ url: URL) -> RecordingCompactionPlan.TrackFacts.Stamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return stamp(of: info)
    }

    /// The file a path names now, for telling it from one put in its place.
    nonisolated static func liveIdentity(_ url: URL) -> RecordingCompactionPlan.FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return .init(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size))
    }

    nonisolated private static func stamp(of info: stat) -> RecordingCompactionPlan.TrackFacts.Stamp {
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return .init(size: Int64(info.st_size), modified: modified)
    }

    /// The system calls `renameExclusive` makes, each returning 0 or the
    /// `errno` it failed with. Injectable so a test can play a volume without
    /// an exclusive rename or without hard links.
    struct RenameCalls: Sendable {
        var renameExclusive: @Sendable (URL, URL) -> Int32
        var link: @Sendable (URL, URL) -> Int32
        var unlink: @Sendable (URL) -> Int32
        var rename: @Sendable (URL, URL) -> Int32
        var exists: @Sendable (URL) -> Bool

        static let live = Self(
            renameExclusive: { posix($0, $1) { renamex_np($0, $1, UInt32(RENAME_EXCL)) } },
            link: { posix($0, $1) { Darwin.link($0, $1) } },
            unlink: { url in
                url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return EIO }
                    return outcome(Darwin.unlink(path))
                }
            },
            rename: { posix($0, $1) { Darwin.rename($0, $1) } },
            exists: { var info = stat(); return lstat($0.path, &info) == 0 },
        )

        private static func posix(_ from: URL, _ to: URL, _ call: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32) -> Int32 {
            from.withUnsafeFileSystemRepresentation { source in
                to.withUnsafeFileSystemRepresentation { target -> Int32 in
                    guard let source, let target else { return EIO }
                    return outcome(call(source, target))
                }
            }
        }

        /// 0 for a call that returned 0, else its `errno`, read at once; a
        /// failure that left `errno` at 0 is `EIO`, never success.
        private static func outcome(_ result: Int32) -> Int32 {
            guard result != 0 else { return 0 }
            let code = errno
            return code == 0 ? EIO : code
        }
    }

    /// Rename that never replaces a file at `to`: `RENAME_EXCL`; where the
    /// volume refuses that, a hard link (which fails on an existing name)
    /// and then the old name removed; where the link is refused too for any
    /// reason but a taken name (FAT, exFAT: both `ENOTSUP`, measured), the
    /// name checked and renamed in the same main-actor turn as the rest of
    /// the commit. A leftover second name after a failed unlink is a hidden
    /// partial name the sweep removes; the copy keeps its final one.
    nonisolated static func renameExclusive(_ from: URL, _ to: URL) throws {
        try renameExclusive(from, to, calls: .live)
    }

    nonisolated static func renameExclusive(_ from: URL, _ to: URL, calls: RenameCalls) throws {
        func fail(_ code: Int32) -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let renamed = calls.renameExclusive(from, to)
        guard renamed != 0 else { return }
        guard [ENOTSUP, EOPNOTSUPP, EINVAL].contains(renamed) else { throw fail(renamed) }
        let linked = calls.link(from, to)
        if linked == 0 {
            _ = calls.unlink(from)
            return
        }
        // Taken is taken; any other refusal (no hard links on this volume,
        // in whatever errno it says so) falls through to the checked rename.
        guard linked != EEXIST else { throw fail(linked) }
        guard !calls.exists(to) else { throw fail(EEXIST) }
        let moved = calls.rename(from, to)
        guard moved == 0 else { throw fail(moved) }
    }

    /// Remove the hidden partial copies (`.<name>.partial.flac`) in `folder`
    /// whose status last changed before `cutoff`, except those `keeping`
    /// names. The status-change time, not the modification time, for the
    /// reason `WatchLoop.removeStaleTemporaryCopies` gives: a partial carries
    /// its source's dates, so its modification time is the recording's age,
    /// while writing and renaming it set its status-change time. Only regular
    /// files of exactly that pattern; nothing else in the folder is looked at.
    nonisolated static func liveSweep(folder: URL, olderThan cutoff: Date, keeping: Set<String>) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for url in names where isPartialCopy(url.lastPathComponent)
            && !keeping.contains(RecordingRetentionPolicy.pathKey(url)) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .attributeModificationDateKey]),
                  values.isRegularFile == true,
                  let changed = values.attributeModificationDate, changed < cutoff else { continue }
            if (try? RecordingFileDeleter.unlinkFile(url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Whether `name` is a partial copy's: hidden, ending in `.partial.flac`,
    /// with a track name in between.
    nonisolated static func isPartialCopy(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(KeptRecordingCompressor.partialSuffix) else { return false }
        let inner = String(name.dropFirst().dropLast(KeptRecordingCompressor.partialSuffix.count))
        return RecordingFileSuffix.keptTrack(of: inner + "." + RecordingFileSuffix.compressedExtension) != nil
    }

    /// The bytes a copy saved: its source's size less its own.
    static func savedBytes(
        source: RecordingCompactionPlan.TrackFacts.Source, copy: RecordingCompactionPlan.FileIdentity?,
    ) -> Int64 {
        guard case let .regular(stamp) = source, let copy else { return 0 }
        return stamp.size - copy.size
    }

    /// Rewrite the `files` of the entry's recording sidecar to the names the
    /// entry lists now, on the main actor. The sidecar is the one the entry
    /// lists now: an AI-title rename in the meantime moved it, and a write
    /// under the old name would recreate an untracked file. `files.mix` is
    /// always written, so the sidecar keeps its shape.
    func rewriteSidecar(jobID: UUID, root: URL) {
        guard let entry = registry.entry(of: jobID, under: root),
              let sidecarURL = entry.paths.first(where: RecordingRetentionPolicy.isRecordingSidecar),
              let sidecar = RecordingSidecar.read(from: sidecarURL) else { return }
        let listedNames = Set(entry.paths.map(\.lastPathComponent))
        let rewritten = sidecar.withTrackNames { name in
            guard let track = RecordingFileSuffix.keptTrack(of: name) else { return name }
            // The listed spelling, the WAV first: a file still there wins.
            return RecordingFileSuffix.keptExtensions.lazy
                .map { track.stem + RecordingFileSuffix.kept(track.suffix, extension: $0) }
                .first(where: listedNames.contains) ?? name
        }
        guard rewritten.files != sidecar.files else { return }
        do {
            try rewritten.write(to: sidecarURL)
        } catch {
            logger.warning("Compaction could not rewrite a recording sidecar: \(error.localizedDescription, privacy: .private)")
        }
    }
}
