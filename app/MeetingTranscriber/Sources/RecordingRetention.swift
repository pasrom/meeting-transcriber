import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingRetention")

/// Deletes files off the main actor.
///
/// A remove can stall for seconds on a folder Spotlight is indexing, the same
/// stall `SnapshotWriterActor` keeps away from the UI for the queue snapshot.
/// Awaiting this actor is a real suspension, so the deletes never run on the
/// caller's thread.
actor RecordingFileDeleter {
    private let remove: @Sendable (URL) throws -> Void

    /// Removes one file with `unlink(2)`, which fails on a folder and removes
    /// a link rather than what it points to. Unlike `removeItem`, it cannot
    /// take a folder's contents with it, so a folder that replaced the file
    /// after the last check is safe even in that window.
    static func unlinkFile(_ url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path in path.map(unlink) ?? -1 }
        guard result != 0 else { return }
        let code = errno
        if code == ENOENT { throw CocoaError(.fileNoSuchFile) }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    init(remove: @escaping @Sendable (URL) throws -> Void = RecordingFileDeleter.unlinkFile) {
        self.remove = remove
    }

    /// Delete each of `urls` and return the ones that are gone afterwards,
    /// including those already missing. A failure is logged and the file left
    /// out of the result, so it stays listed for the next pass.
    ///
    /// Only regular files are removed. A path that is now a folder or a link
    /// is skipped and stays listed: removing a folder would take everything
    /// in it, and a link is not the recording.
    func delete(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard RecordingRetentionPolicy.isRegularFileOrGone(url) else {
                logger.warning("Retention skipped a listed path that is not a regular file")
                return false
            }
            do {
                try remove(url)
                return true
            } catch CocoaError.fileNoSuchFile {
                return true
            } catch {
                // Private: a file-system error names the file, and the file name
                // is the meeting title.
                logger.warning("Could not delete a retained recording: \(error.localizedDescription, privacy: .private)")
                return false
            }
        }
    }
}

/// Deletes relocated recordings once the retention setting says they are due.
///
/// Decisions and every registry change happen on the main actor; only the
/// deletes leave it. The settings are read through a closure on every pass, so
/// switching retention on, off or to a shorter period takes effect on the next
/// pass without rebuilding anything.
///
/// Known limits, accepted:
/// - Each delete is checked right before it runs, but the check and the
///   unlink are not one step. A due recording re-imported during the few
///   seconds a stalled unlink is in flight can still be lost; it is the file
///   this pass was about to delete anyway, and the new job then fails with a
///   missing-file error.
/// - Files are identified by path. A file, or a folder link pointed
///   elsewhere, placed at an old path takes on the old entry's deletion, and
///   paths that name the same file through letter case or a system alias are
///   not treated as one.
/// - Entries under an earlier output folder stay unreachable while another
///   folder's access is held, so they and their files stay until that folder
///   is chosen again.
/// - If an unreadable registry file cannot be moved aside, the entries it
///   held are no longer tracked.
/// - A process kill between the AI-title rename and the registry update
///   leaves that recording untracked.
@MainActor
final class RecordingRetention {
    /// What one pass needs from the queue that asks for it.
    struct SweepContext {
        /// Standardized paths of every track a job that is not finished holds,
        /// read once per pass, right before deciding.
        let excludedPaths: () -> Set<String>
        /// The output folder as resolved from its bookmark, or nil when the
        /// queue has none. Access is opened on this exact object, since a URL
        /// rebuilt from a path carries no sandbox grant.
        let scopeRoot: URL?
        let securityScope: SecurityScopeAccess
    }

    let registry: RecordingRetentionRegistry

    /// Paths held by the unfinished jobs of the queue currently in use, set by
    /// the controller. Read with the pass's own on every check, because a pass
    /// started from an earlier queue would otherwise not see jobs that arrive
    /// in the one that replaced it.
    var heldPaths: () -> Set<String> = { [] }

    /// Whether a compaction run is expected to remove the WAV of a track an
    /// entry lists beside its FLAC, set by the controller from
    /// `RecordingCompaction.pairResolves`. For such an entry the size pass
    /// counts the pair once, as the FLAC; otherwise both files count. Called
    /// once per measure and once per deleted recording, and the predicate it
    /// returns once per entry, so the output folder it compares with is
    /// resolved once per call rather than per entry.
    var pairResolves: () -> (RetainedRecording) -> Bool = { { _ in false } }

    private func inUse(_ context: SweepContext) -> Set<String> {
        context.excludedPaths().union(heldPaths())
    }

    private let settings: () -> RecordingRetentionSettings
    private let storageLimit: () -> RecordingStorageLimitSettings
    private let alarm: RecordingStorageAlarm
    /// Told on each storage-limit warning: total, limit.
    private let onLimitReached: (Int64, Int64) -> Void
    /// Told after each storage-limit pass; nil while the limit is off.
    private let onStatus: (RecordingStorageStatus?) -> Void
    private let deleter: RecordingFileDeleter
    private let now: () -> Date
    /// Told once per pass that looks at entries; see `init`.
    private let report: (RecordingRetentionPassSummary) -> Void

    /// The pass running now, so a second request waits for it instead of
    /// deleting the same files twice.
    private var running: Task<Void, Never>?
    /// The newest context asked for while a pass was running, served by one
    /// more pass when it ends.
    private var pending: SweepContext?

    /// `report` defaults to one info line per pass, so a log shows that a pass
    /// ran and why it kept what it kept. Public: the line holds counts and
    /// reason names only.
    init(
        registry: RecordingRetentionRegistry,
        settings: @escaping () -> RecordingRetentionSettings,
        now: @escaping () -> Date = Date.init,
        deleter: RecordingFileDeleter = RecordingFileDeleter(),
        storageLimit: @escaping () -> RecordingStorageLimitSettings = { .off },
        alarm: RecordingStorageAlarm = .inMemory(),
        onLimitReached: @escaping (Int64, Int64) -> Void = { _, _ in },
        onStatus: @escaping (RecordingStorageStatus?) -> Void = { _ in },
        report: @escaping (RecordingRetentionPassSummary) -> Void = { logger.info("\($0.logLine, privacy: .public)") },
    ) {
        self.registry = registry
        self.settings = settings
        self.storageLimit = storageLimit
        self.alarm = alarm
        self.onLimitReached = onLimitReached
        self.onStatus = onStatus
        self.deleter = deleter
        self.now = now
        self.report = report
        settled = settings()
        settledStorage = storageLimit()
    }

    /// The size of a regular file, 0 for anything else. Not followed through
    /// a symlink, like the delete.
    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return 0 }
        return Int64(attributes[.size] as? Int ?? 0)
    }

    /// Waiting to run `afterSettling`'s action; replaced by each new call.
    private var settling: Task<Void, Never>?

    /// Run `action` once no further call has arrived for `delay`.
    func afterSettling(for delay: Duration, _ action: @escaping @MainActor () async -> Void) {
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    /// The settings as they were when they last settled; see `settle`.
    private var settled: RecordingRetentionSettings

    /// Adopt the current settings as the ones a pass acts on. Called once a
    /// change has stopped moving, so a value the stepper only passes through
    /// never reaches any pass, whoever starts it.
    func settle() {
        settled = settings()
        settledStorage = storageLimit()
    }

    private var settledStorage: RecordingStorageLimitSettings

    /// The settings as they are now. Reading it inside
    /// `withObservationTracking` observes both underlying settings.
    var currentSettings: RecordingRetentionSettings {
        settings()
    }

    /// The storage limit as it is now; observed alongside `currentSettings`.
    var currentStorageLimit: RecordingStorageLimitSettings {
        storageLimit()
    }

    /// The storage limit a pass acts on. Like `effectiveSettings`: switching
    /// off and raising the limit apply at once, the other directions settle.
    var effectiveStorageLimit: RecordingStorageLimitSettings {
        let live = storageLimit()
        return RecordingStorageLimitSettings(
            enabled: settledStorage.enabled && live.enabled,
            limitBytes: max(settledStorage.limitBytes, live.limitBytes),
        )
    }

    /// Whether either rule could delete anything, so a pass is worth running.
    var isActive: Bool {
        effectiveSettings.enabled || effectiveStorageLimit.enabled
    }

    /// What a pass acts on: the settled settings, except that switching off
    /// and lengthening the period apply at once. Only the direction that
    /// deletes waits to settle.
    var effectiveSettings: RecordingRetentionSettings {
        let live = settings()
        return RecordingRetentionSettings(
            enabled: settled.enabled && live.enabled, days: max(settled.days, live.days),
        )
    }

    /// Run one pass, or join the one already running and make sure another
    /// follows it. Returns once the work asked for is done.
    func sweep(_ context: SweepContext) async {
        if let running {
            pending = context
            await running.value
            return
        }
        let task = Task { [self] in
            var next: SweepContext? = context
            while let current = next {
                pending = nil
                await sweepOnce(current)
                next = pending
            }
            running = nil
        }
        running = task
        await task.value
    }

    private func sweepOnce(_ context: SweepContext) async {
        await sweepByAge(context)
        await sweepBySize(context)
    }

    private func sweepByAge(_ context: SweepContext) async {
        // Off, every entry is kept, so there is nothing to work out.
        guard effectiveSettings.enabled, !registry.entries.isEmpty else { return }
        guard registry.persist() else {
            logger.warning("Retention pass skipped: the registry could not be saved")
            return
        }
        let current = effectiveSettings
        let environment = RecordingRetentionPolicy.Environment.live(
            excludedPaths: inUse(context), scopedRoot: context.scopeRoot,
        )
        let instant = now()
        var due: [(jobID: UUID, urls: [URL])] = []
        var dropped: [RetainedRecording] = []
        var outside = 0
        // Reported on every way out below, with what the deletes achieved.
        var summary = RecordingRetentionPassSummary()
        defer { report(summary) }
        for entry in registry.entries {
            let decision = RecordingRetentionPolicy.decide(
                entry, now: instant, settings: current, environment: environment,
            )
            summary.count(decision)
            switch decision {
            case let .delete(urls):
                due.append((entry.jobID, urls))
                outside += entry.paths.count { path in
                    !RecordingRetentionPolicy.isInRecordingsFolder(path, of: entry.root, in: environment)
                }

            case .drop(.filesGone):
                dropped.append(entry)

            case .keep(.outsideRoot):
                outside += entry.paths.count

            case .keep:
                break
            }
        }
        if outside > 0 {
            logger.warning("Retention skipped \(outside, privacy: .public) listed files outside the recordings folder")
        }
        registry.remove(dropped)
        guard !due.isEmpty else { return }

        // No delete without the scope when one is held: in the sandbox it
        // would fail anyway, and outside it nothing should depend on that.
        if let scopeRoot = context.scopeRoot {
            guard context.securityScope.start(scopeRoot) else {
                logger.warning("Retention pass skipped: the output folder's access could not be opened")
                return
            }
        }
        defer { context.scopeRoot.map(context.securityScope.stop) }

        for (jobID, urls) in due {
            var gone: [URL] = []
            for url in urls {
                // Checked again right before each delete, on the main actor: a
                // job may have taken a track into use, a newer recording may
                // have taken the path over, the settings may have been switched
                // off or lengthened, or a registry write may have failed since
                // the decision.
                guard registry.isPersisted,
                      let entry = registry.entry(listing: url, for: jobID),
                      RecordingRetentionPolicy.isDue(entry, now: now(), settings: effectiveSettings),
                      !RecordingRetentionPolicy.isInUse(entry, excludedPaths: inUse(context))
                else { break }
                gone += await deleter.delete([url])
            }
            // One write per recording. Forgetting after the deletes is safe:
            // a listed file that is gone is dropped by the next pass, and a
            // path a newer recording takes over leaves this entry on its own.
            registry.forget(gone, of: jobID)
            summary.deletedFiles += gone.count
        }
    }

    /// The storage-limit pass. Counts every tracked file it can reach; when
    /// the total is over the limit it warns, waits out the grace period, then
    /// deletes the oldest recordings the age rules would let go of (outputs
    /// written, not in use, inside the recordings folder) until the total
    /// fits. Only recordings deletable when the warning was given are deleted
    /// under it; one that becomes deletable later gets a warning of its own. Recordings
    /// still waiting for their outputs count but are never deleted.
    private func sweepBySize(_ context: SweepContext) async {
        let limit = effectiveStorageLimit
        guard limit.enabled else {
            if alarm.load() != nil { alarm.save(nil) }
            onStatus(nil)
            return
        }
        guard registry.persist() else {
            logger.warning("Storage limit pass skipped: the registry could not be saved")
            return
        }
        let instant = now()
        let rootKey = context.scopeRoot.map(RecordingRetentionPolicy.pathKey)
        let (total, candidates, gone) = measure(context, now: instant)
        // The age pass drops these too, but it does not run while it is off.
        registry.remove(gone)
        let step = RecordingStorageLimitPolicy.step(
            totalBytes: total, settings: limit, warning: alarm.load(), root: rootKey, now: instant,
        )
        var picked: [RecordingStorageLimitPolicy.Candidate] = []
        var result = (files: 0, bytes: Int64(0))
        switch step {
        case .clear:
            if alarm.load() != nil { alarm.save(nil) }

        case .warn:
            warn(totalBytes: total, limitBytes: limit.limitBytes, root: rootKey, at: instant)

        case .wait:
            break

        case .delete:
            guard let warning = alarm.load() else { break }
            picked = RecordingStorageLimitPolicy.selectForDeletion(
                candidates.filter(warning.covers), totalBytes: total, limitBytes: limit.limitBytes,
            )
            result = await delete(picked, context, totalBytes: total)
            // Switched off while deleting: the setting has cleared the warning.
            let live = effectiveStorageLimit
            guard live.enabled else { break }
            let remaining = total - result.bytes
            if remaining <= live.limitBytes {
                alarm.save(nil)
            } else if RecordingStorageLimitPolicy.needsNewWarning(
                remainingBytes: remaining, limitBytes: live.limitBytes,
                uncovered: candidates.filter { !warning.covers($0) },
            ) {
                warn(totalBytes: remaining, limitBytes: live.limitBytes, root: rootKey, at: now())
            }
        }
        let deletableBytes = candidates.reduce(0) { $0 + $1.bytes }
        onStatus(effectiveStorageLimit.enabled ? RecordingStorageStatus(
            totalBytes: total - result.bytes, keptBytes: total - deletableBytes, warning: alarm.load(),
        ) : nil)
        logger.info(
            """
            Storage limit pass: \(String(describing: step), privacy: .public), total \(total, privacy: .public) \
            of \(limit.limitBytes, privacy: .public) bytes, deletable \(candidates.count, privacy: .public), \
            picked \(picked.count, privacy: .public), deleted files \(result.files, privacy: .public), \
            counted total down by \(result.bytes, privacy: .public) bytes (up when negative), \
            warning \(self.alarm.load() != nil, privacy: .public)
            """,
        )
    }

    /// Tell the user, then store the warning: a crash in between warns twice
    /// rather than starting a grace period nobody was told about.
    private func warn(totalBytes: Int64, limitBytes: Int64, root: String?, at instant: Date) {
        onLimitReached(totalBytes, limitBytes)
        alarm.save(RecordingStorageWarning(since: instant, limitBytes: limitBytes, root: root))
    }

    /// The bytes every reachable listed file takes and the recordings the
    /// age rule would let go of with a period of 0 days.
    private func measure(
        _ context: SweepContext, now instant: Date,
    ) -> (total: Int64, candidates: [RecordingStorageLimitPolicy.Candidate], gone: [RetainedRecording]) {
        let environment = RecordingRetentionPolicy.Environment.live(
            excludedPaths: inUse(context), scopedRoot: context.scopeRoot,
        )
        let resolves = pairResolves()
        var total: Int64 = 0
        var candidates: [RecordingStorageLimitPolicy.Candidate] = []
        var gone: [RetainedRecording] = []
        for entry in registry.entries {
            if let scoped = context.scopeRoot,
               RecordingRetentionPolicy.pathKey(scoped) != RecordingRetentionPolicy.pathKey(entry.root) { continue }
            guard environment.fileExists(entry.root) else { continue }
            let bytes = countedBytes(of: entry, in: environment, pairResolves: resolves)
            total += bytes
            switch RecordingRetentionPolicy.decide(entry, now: instant, settings: Self.anyAge, environment: environment) {
            case let .delete(urls):
                // `decide` deletes only an entry with `eligibleAt` set. It
                // lists every file `countedBytes` counts, so `bytes` is what
                // deleting them frees.
                candidates.append(.init(
                    jobID: entry.jobID, root: entry.root, recordedAt: entry.recordedAt,
                    eligibleAt: entry.eligibleAt ?? instant, urls: urls, bytes: bytes,
                ))

            case .drop(.filesGone):
                gone.append(entry)

            case .keep:
                break
            }
        }
        return (total, candidates, gone)
    }

    /// The bytes `entry`'s listed files take on disk in its recordings
    /// folder, as the size pass counts them: for an entry `pairResolves`
    /// accepts, a WAV whose FLAC is listed and on disk beside it counts
    /// nothing. Deleting the entry still removes both.
    private func countedBytes(
        of entry: RetainedRecording, in environment: RecordingRetentionPolicy.Environment,
        pairResolves: (RetainedRecording) -> Bool,
    ) -> Int64 {
        var counted = entry.paths
            .filter { RecordingRetentionPolicy.isInRecordingsFolder($0, of: entry.root, in: environment) }
            .filter(environment.fileExists)
        if pairResolves(entry) {
            let keys = Set(counted.map(RecordingRetentionPolicy.pathKey))
            counted = counted.filter { url in
                guard let flac = KeptRecordingCompressor.compressedURL(for: url) else { return true }
                return !keys.contains(RecordingRetentionPolicy.pathKey(flac))
            }
        }
        return counted.reduce(0) { $0 + fileSize($1) }
    }

    /// The age rule's checks with no period: due as soon as it is safe.
    private static let anyAge = RecordingRetentionSettings(enabled: true, days: 0)

    /// Delete `picked`, rechecking each file as the age pass does, and stop
    /// once the live limit is met, so raising it mid-pass applies at once.
    /// Returns the files deleted and the bytes freed, as `measure` counts
    /// them: per recording, its counted bytes before less what its entry, as
    /// it is now, counts after. So what another writer did meanwhile (a
    /// rename, the compactor writing a FLAC) counts as it stands, and a
    /// delete that failed or was cut off while the FLAC went leaves a WAV
    /// that counted nothing before and counts in full now: what is freed can
    /// be negative.
    private func delete(
        _ picked: [RecordingStorageLimitPolicy.Candidate], _ context: SweepContext, totalBytes: Int64,
    ) async -> (files: Int, bytes: Int64) {
        guard !picked.isEmpty else { return (0, 0) }
        if let scopeRoot = context.scopeRoot {
            guard context.securityScope.start(scopeRoot) else {
                logger.warning("Storage limit pass skipped: the output folder's access could not be opened")
                return (0, 0)
            }
        }
        defer { context.scopeRoot.map(context.securityScope.stop) }
        var freed: Int64 = 0
        var deletedFiles = 0
        for candidate in picked {
            let live = effectiveStorageLimit
            guard live.enabled, totalBytes - freed > live.limitBytes else { break }
            var gone: [URL] = []
            for url in candidate.urls {
                guard registry.isPersisted, effectiveStorageLimit.enabled,
                      let entry = registry.entry(listing: url, for: candidate.jobID),
                      RecordingRetentionPolicy.isDue(entry, now: now(), settings: Self.anyAge),
                      !RecordingRetentionPolicy.isInUse(entry, excludedPaths: inUse(context))
                else { break }
                gone += await deleter.delete([url])
            }
            registry.forget(gone, of: candidate.jobID)
            let environment = RecordingRetentionPolicy.Environment.live(
                excludedPaths: inUse(context), scopedRoot: context.scopeRoot,
            )
            let after = registry.entry(of: candidate.jobID, under: candidate.root).map { entry in
                countedBytes(of: entry, in: environment, pairResolves: pairResolves())
            } ?? 0
            freed += candidate.bytes - after
            deletedFiles += gone.count
        }
        return (deletedFiles, freed)
    }
}
