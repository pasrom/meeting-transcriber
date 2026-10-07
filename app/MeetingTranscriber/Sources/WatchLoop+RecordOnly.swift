import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The record-only output branch, split out of `WatchLoop.swift` to keep that
/// file under the line cap. An extension of a globally `@MainActor`-isolated
/// type inherits that isolation, so the moved methods need no annotation.
/// Failures are reported by `reportRecordOnlyFailure`.
extension WatchLoop {
    func writeRecordOnlySidecar(
        title: String,
        appName: String,
        recording: RecordingResult,
        trigger: RecordingSidecar.Trigger,
        participants: [String],
    ) throws {
        let kept = try makeRecordOnlyWrite(
            title: title, appName: appName, recording: recording, trigger: trigger, participants: participants,
        ).perform()
        reportStagingFilesKept(kept)
    }

    /// `writeRecordOnlySidecar` with the file work on a detached task, for a
    /// quit: its budget is a timer on the main actor, and moving the tracks
    /// into an output folder on another volume is a copy that takes as long
    /// as the mix did. Failures are reported as on the synchronous path.
    func writeRecordOnlyOffMain(
        title: String,
        appName: String,
        recording: RecordingResult,
        trigger: RecordingSidecar.Trigger,
        participants: [String],
    ) async {
        let write = makeRecordOnlyWrite(
            title: title, appName: appName, recording: recording, trigger: trigger, participants: participants,
        )
        do {
            let kept = try await Task.detached(priority: .userInitiated) { try write.perform() }.value
            reportStagingFilesKept(kept)
        } catch {
            reportRecordOnlyFailure(error)
        }
    }

    /// A committed write whose staging files could not be removed: the next
    /// launch's orphan scan picks the mix up and processes the recording again,
    /// next to its record-only output. Said once, not per file.
    func reportStagingFilesKept(_ kept: [URL]) {
        guard !kept.isEmpty else { return }
        notifier.notify(
            title: "Record-only: files left in staging",
            body: "The recording was written, but \(kept.count) of its staging files could not be removed. "
                + "The next launch will process it again.",
            urgency: .standard,
        )
    }

    /// Record-only performs no state transition, so this is the entire report
    /// that a recording was lost. Error left redacted: a sidecar/WAV write
    /// error embeds the meeting-title-derived basename in its description.
    func reportRecordOnlyFailure(_ error: any Error) {
        logger.error("Record-only: \(error.localizedDescription)")
        update { next in
            next.lastError = "Record-only output failed: \(error.localizedDescription)"
        }
        // Breaks through Focus on the same test as `captureAlert`: a failed
        // write has no benign reading.
        notifier.notify(
            title: "Record-only output failed",
            body: error.localizedDescription,
            urgency: .timeSensitive,
        )
    }

    /// Everything the write needs, taken here on the main actor: the
    /// destination is resolved from settings and the stop time is now.
    private func makeRecordOnlyWrite(
        title: String,
        appName: String,
        recording: RecordingResult,
        trigger: RecordingSidecar.Trigger,
        participants: [String],
    ) -> RecordOnlyWrite {
        RecordOnlyWrite(
            title: title,
            appName: appName,
            recording: recording,
            trigger: trigger,
            participants: participants,
            // Guard the sidecar's startedAt <= stoppedAt invariant against a
            // backward wall-clock step between start and stop (e.g. NTP
            // correcting a fast clock): never emit a negative interval for
            // downstream fleet consumers that compute a duration from the pair.
            stoppedAt: max(Date(), recording.recordingStartDate),
            destination: recordOnlyDestination(),
            transfer: recordOnlyFileTransfer,
        )
    }
}

/// One record-only write: the WAVs put into the destination and the sidecar
/// written next to them. Pure I/O over values, so it runs on any thread.
///
/// It can be cut off at any point: on a quit it gets what is left of the
/// recording budget, and into an output folder on another volume each file is
/// a copy. So it commits in this order, and the staging folder keeps every
/// source until the end:
///   1. a complete copy of each file under a temporary name in the destination,
///   2. each renamed to its final name,
///   3. the sidecar, which says the recording is complete,
///   4. the sources removed, the mix first.
/// Cut off before 3, the destination holds no truncated file under a final
/// name, and the staging mix is still there for the next launch's orphan scan.
struct RecordOnlyWrite: Sendable {
    /// Puts a complete copy of the first file at the second path.
    typealias Transfer = @Sendable (URL, URL) throws -> Void

    /// A hard link where source and destination share a volume (instant,
    /// nothing is copied), a copy where they do not.
    static let linkOrCopy: Transfer = { source, target in
        if link(source.path, target.path) == 0 { return }
        try FileManager.default.copyItem(at: source, to: target)
    }

    let title: String
    let appName: String
    let recording: RecordingResult
    let trigger: RecordingSidecar.Trigger
    let participants: [String]
    let stoppedAt: Date
    let destination: RecordOnlyDestination
    let transfer: Transfer
    /// Writes the sidecar to the file it is given (a temporary name; see
    /// `commitSidecar`). A seam so a test can make it fail before or after the
    /// file is written.
    var writeSidecar: SidecarWriter = { try $0.write(to: $1) }

    typealias SidecarWriter = @Sendable (RecordingSidecar, URL) throws -> Void

    @discardableResult
    func perform() throws -> [URL] {
        let mixName = recording.mixPath.lastPathComponent
        let basename = RecordingFileSuffix.stripSuffix(from: mixName)?.stem
            ?? recording.mixPath.deletingPathExtension().lastPathComponent

        // start/stopAccessingSecurityScopedResource MUST be called on the
        // URL that resolved from the bookmark (App Store sandboxed build,
        // or any custom Output Folder pick) — calling it on a child path
        // silently fails. We then write into the `recordings/` subfolder
        // beneath that scope.
        let accessing = destination.scope.startAccessingSecurityScopedResource()
        defer { if accessing { destination.scope.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let destDir = destination.writeDir
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        Self.removeStaleTemporaryCopies(
            in: destDir, changedBefore: Date().addingTimeInterval(-Self.staleTemporaryCopyAge),
        )

        let sources = [recording.mixPath] + [recording.appPath, recording.micPath].compactMap(\.self)
        // Nothing of an earlier recording in the folder is removed or
        // overwritten. One with the same stem (two recordings in one second,
        // or a clock set back) makes this write take a stem of its own,
        // chosen before anything is written.
        let suffixes = sources.map { Self.suffix(of: $0.lastPathComponent, after: basename) }
        let stem = try Self.freeStem(basename, for: suffixes, in: destDir)
        let finalNames = suffixes.map { stem + $0 }
        let sidecarURL = destDir.appendingPathComponent(stem + RecordingSidecar.filenameSuffix)
        try Self.placeCopies(of: Array(zip(sources, finalNames)), in: destDir, using: transfer)

        let sidecar = RecordingSidecar(
            title: title,
            appName: appName,
            startedAt: recording.recordingStartDate,
            stoppedAt: stoppedAt,
            participants: participants,
            micDelaySeconds: recording.micDelay,
            trigger: trigger,
            mixFilename: finalNames[0],
            appFilename: recording.appPath.map { stem + Self.suffix(of: $0.lastPathComponent, after: basename) },
            micFilename: recording.micPath.map { stem + Self.suffix(of: $0.lastPathComponent, after: basename) },
        )
        try commitSidecar(sidecar, at: sidecarURL)
        let notRemoved = Self.removeSources(sources)
        logger.info("Record-only: wrote sidecar + WAVs to \(destDir.path) for \(title, privacy: .private)")
        return notRemoved
    }

    /// What follows the stem in a recording file's name (`_mix.wav`, ...).
    private static func suffix(of name: String, after stem: String) -> String {
        name.hasPrefix(stem) ? String(name.dropFirst(stem.count)) : "_" + name
    }

    /// `stem`, or `stem-2`, `stem-3`, ... : the first whose final names (the
    /// files and the sidecar) and their temporary names are all free in `dir`.
    private static func freeStem(_ stem: String, for suffixes: [String], in dir: URL) throws -> String {
        let fm = FileManager.default
        let all = suffixes + [RecordingSidecar.filenameSuffix]
        for attempt in 1 ... 100 {
            let candidate = attempt == 1 ? stem : "\(stem)-\(attempt)"
            let taken = all.contains { suffix in
                let name = candidate + suffix
                return fm.fileExists(atPath: dir.appendingPathComponent(name).path)
                    || fm.fileExists(atPath: dir.appendingPathComponent(temporaryName(for: name)).path)
            }
            if !taken { return candidate }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Steps 1 and 2: a complete copy of each source under the temporary name
    /// of its final name, then each moved into place. Nothing is replaced: a
    /// move onto a name that exists fails. On a failure the temporary copies
    /// go.
    private static func placeCopies(of files: [(source: URL, finalName: String)], in destDir: URL, using transfer: Transfer) throws {
        let fm = FileManager.default
        var staged: [(temp: URL, final: URL)] = []
        do {
            for file in files {
                let temp = destDir.appendingPathComponent(temporaryName(for: file.finalName))
                staged.append((temp, destDir.appendingPathComponent(file.finalName)))
                try transfer(file.source, temp)
            }
            for file in staged {
                try fm.moveItem(at: file.temp, to: file.final)
            }
        } catch {
            for file in staged {
                try? fm.removeItem(at: file.temp)
            }
            throw error
        }
    }

    /// Step 3, the commit: the sidecar written under its temporary name and
    /// renamed into place. The rename is what commits, so only this call's
    /// file can commit it: the stem was chosen so that neither the temporary
    /// nor the final name exists, and the rename refuses to replace a file. A
    /// step of the write that fails after the content is written (the
    /// owner-only permission change, on a file system that refuses it) is
    /// logged and does not stop the commit, since keeping the sources would
    /// have the next launch process the recording again.
    private func commitSidecar(_ sidecar: RecordingSidecar, at sidecarURL: URL) throws {
        let fm = FileManager.default
        let temp = sidecarURL.deletingLastPathComponent()
            .appendingPathComponent(Self.temporaryName(for: sidecarURL.lastPathComponent))
        try? fm.removeItem(at: temp)
        do {
            try writeSidecar(sidecar, temp)
        } catch {
            guard fm.fileExists(atPath: temp.path) else { throw error }
            logger.error("Record-only: sidecar written, a step after it failed: \(error.localizedDescription)")
        }
        // RENAME_EXCL: never onto a sidecar that exists, whoever wrote it.
        guard renamex_np(temp.path, sidecarURL.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(code)])
        }
    }

    /// The hidden temporary name a file is written under before it is renamed
    /// to `name`.
    static func temporaryName(for name: String) -> String {
        ".\(name).partial"
    }

    /// Whether `name` is a temporary name this code produces: one of a
    /// recording's files (`<yyyyMMdd_HHmmss>`, with the `-<n>` a stem collision
    /// adds, plus a mix, track or sidecar suffix) behind `temporaryName`. The folder is the user's, so nothing
    /// else is ever taken for a leftover.
    static func isTemporaryCopyName(_ name: String) -> Bool {
        let suffixes = [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic, RecordingSidecar.filenameSuffix]
        return suffixes.contains { suffix in
            let escaped = NSRegularExpression.escapedPattern(for: suffix)
            return name.range(of: #"^\.\d{8}_\d{6}(-\d+)?"# + escaped + #"\.partial$"#, options: .regularExpression) != nil
        }
    }

    /// Remove the staging sources of a committed write, the mix first: a mix
    /// left behind would be picked up by the orphan scan and processed a
    /// second time; a track left behind is only litter. Returns, and logs,
    /// each one that stays.
    private static func removeSources(_ sources: [URL]) -> [URL] {
        let fm = FileManager.default
        var notRemoved: [URL] = []
        for source in sources {
            do {
                try fm.removeItem(at: source)
            } catch {
                guard fm.fileExists(atPath: source.path) else { continue }
                notRemoved.append(source)
                logger.error(
                    "Record-only: \(source.lastPathComponent) stays in staging after the write; the next launch processes it again",
                )
            }
        }
        return notRemoved
    }

    /// How old a temporary copy must be before a write treats it as left by
    /// one the exit cut off. A copy still in progress is younger.
    static let staleTemporaryCopyAge: TimeInterval = 600

    /// Remove temporary copies a cut-off write left in `dir`. Nothing else
    /// would: their names carry a timestamp, so no later write reuses them.
    /// Only names `isTemporaryCopyName` accepts, and only ones whose status
    /// last changed before `cutoff`: a copy carries its source's modification
    /// time (a hard link is the source, a copy takes its dates), so that time
    /// says nothing about when the copy was made, while creating it, linking
    /// it and renaming it all set its status-change time.
    static func removeStaleTemporaryCopies(in dir: URL, changedBefore cutoff: Date) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where isTemporaryCopyName(name) {
            let url = dir.appendingPathComponent(name)
            guard let changed = try? url.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate,
                  changed < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }
}

/// Pair of URLs used by `WatchLoop` when persisting record-only output: the
/// `scope` URL is what `startAccessingSecurityScopedResource()` is called on
/// (the bookmark-resolved parent the user actually picked), and `writeDir` is
/// the sub-path under that scope where the WAV + sidecar files land.
///
/// The split exists because Apple's security-scoped-bookmark API only grants
/// access on the URL that resolved from the bookmark — calling start-access
/// on a *child* path silently fails inside the App Store sandbox while
/// appearing to work in the unsandboxed Homebrew build. The factory methods
/// below make the two cases (real bookmark vs. transient app dir) explicit
/// at every call site.
struct RecordOnlyDestination: Equatable, Sendable {
    let scope: URL
    let writeDir: URL

    /// Production path: `parent` is the user-picked Output Folder (potentially
    /// resolved from a security-scoped bookmark) and the WAVs land under
    /// `parent/recordings/` so a Syncthing or rsync pair has a stable subtree.
    static func production(parent: URL) -> Self {
        Self(
            scope: parent,
            writeDir: parent.appendingPathComponent("recordings", isDirectory: true),
        )
    }

    /// Test/default path: no security scope to manage — `scope == writeDir`,
    /// so start-access is a harmless no-op and the writer hits `url` directly.
    static func unscoped(_ url: URL) -> Self {
        Self(scope: url, writeDir: url)
    }
}
