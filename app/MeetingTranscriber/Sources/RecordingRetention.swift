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

    private func inUse(_ context: SweepContext) -> Set<String> {
        context.excludedPaths().union(heldPaths())
    }

    private let settings: () -> RecordingRetentionSettings
    private let storageLimit: () -> RecordingStorageLimitSettings
    private let alarm: RecordingStorageAlarm
    /// Told once when the recordings go over the storage limit: total, limit.
    private let onLimitReached: (Int64, Int64) -> Void
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
        report: @escaping (RecordingRetentionPassSummary) -> Void = { logger.info("\($0.logLine, privacy: .public)") },
    ) {
        self.registry = registry
        self.settings = settings
        self.storageLimit = storageLimit
        self.alarm = alarm
        self.onLimitReached = onLimitReached
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
    /// the total is over the limit it notifies once, waits out the grace
    /// period, then deletes the oldest recordings the age rules would let go
    /// of (outputs written, not in use, inside the recordings folder) until
    /// the total fits. Recordings still waiting for their outputs count but
    /// are never deleted, so the total can stay over the limit.
    private func sweepBySize(_ context: SweepContext) async {
        let limit = effectiveStorageLimit
        guard limit.enabled else {
            if alarm.load() != nil { alarm.save(nil) }
            return
        }
        guard registry.persist() else { return }
        let instant = now()
        let (total, candidates, gone) = measure(context, now: instant)
        // The age pass drops these too, but it does not run while it is off.
        registry.remove(gone)
        switch RecordingStorageLimitPolicy.step(
            totalBytes: total, settings: limit, exceededSince: alarm.load(), now: instant,
        ) {
        case .clear:
            if alarm.load() != nil { alarm.save(nil) }

        case .warn:
            // Notify before saving: a crash in between then warns twice
            // rather than starting a grace period nobody was told about.
            logger.info("Storage limit reached: \(total, privacy: .public) of \(limit.limitBytes, privacy: .public) bytes")
            onLimitReached(total, limit.limitBytes)
            alarm.save(instant)

        case .wait:
            break

        case .delete:
            let picked = RecordingStorageLimitPolicy.selectForDeletion(
                candidates, totalBytes: total, limitBytes: limit.limitBytes,
            )
            guard !picked.isEmpty else { return }
            let freed = await delete(picked, context)
            if total - freed <= limit.limitBytes { alarm.save(nil) }
        }
    }

    /// The bytes every reachable listed file takes, and the recordings the
    /// age rule would let go of with a period of 0 days.
    private func measure(
        _ context: SweepContext, now instant: Date,
    ) -> (total: Int64, candidates: [RecordingStorageLimitPolicy.Candidate], gone: [RetainedRecording]) {
        let environment = RecordingRetentionPolicy.Environment.live(
            excludedPaths: inUse(context), scopedRoot: context.scopeRoot,
        )
        var total: Int64 = 0
        var candidates: [RecordingStorageLimitPolicy.Candidate] = []
        var gone: [RetainedRecording] = []
        for entry in registry.entries {
            if let scoped = context.scopeRoot,
               RecordingRetentionPolicy.pathKey(scoped) != RecordingRetentionPolicy.pathKey(entry.root) { continue }
            guard environment.fileExists(entry.root) else { continue }
            total += entry.paths
                .filter { RecordingRetentionPolicy.isInRecordingsFolder($0, of: entry.root, in: environment) }
                .filter(environment.fileExists)
                .reduce(0) { $0 + fileSize($1) }
            switch RecordingRetentionPolicy.decide(entry, now: instant, settings: Self.anyAge, environment: environment) {
            case let .delete(urls):
                candidates.append(.init(
                    jobID: entry.jobID, recordedAt: entry.recordedAt, urls: urls,
                    bytes: urls.reduce(0) { $0 + fileSize($1) },
                ))

            case .drop(.filesGone):
                gone.append(entry)

            case .keep:
                break
            }
        }
        return (total, candidates, gone)
    }

    /// The age rule's checks with no period: due as soon as it is safe.
    private static let anyAge = RecordingRetentionSettings(enabled: true, days: 0)

    /// Delete `picked`, rechecking each file as the age pass does, and return
    /// the bytes freed.
    private func delete(_ picked: [RecordingStorageLimitPolicy.Candidate], _ context: SweepContext) async -> Int64 {
        if let scopeRoot = context.scopeRoot {
            guard context.securityScope.start(scopeRoot) else {
                logger.warning("Storage limit pass skipped: the output folder's access could not be opened")
                return 0
            }
        }
        defer { context.scopeRoot.map(context.securityScope.stop) }
        var freed: Int64 = 0
        var deletedFiles = 0
        for candidate in picked {
            var gone: [URL] = []
            for url in candidate.urls {
                guard registry.isPersisted, effectiveStorageLimit.enabled,
                      let entry = registry.entry(listing: url, for: candidate.jobID),
                      RecordingRetentionPolicy.isDue(entry, now: now(), settings: Self.anyAge),
                      !RecordingRetentionPolicy.isInUse(entry, excludedPaths: inUse(context))
                else { break }
                let size = fileSize(url)
                let deleted = await deleter.delete([url])
                gone += deleted
                if !deleted.isEmpty { freed += size }
            }
            registry.forget(gone, of: candidate.jobID)
            deletedFiles += gone.count
        }
        logger.info("Storage limit pass: deleted files \(deletedFiles, privacy: .public), freed \(freed, privacy: .public) bytes")
        return freed
    }
}
