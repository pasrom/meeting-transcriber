import Foundation

/// The scratch `UserDefaults` suites tests make, and their cleanup.
///
/// Every suite lives in a folder of the test process's own under the temporary
/// directory, never in `~/Library/Preferences`. That is what `open(_:)` is for,
/// and why a test must not call `UserDefaults(suiteName:)` itself (a lint rule
/// and `ScratchDefaultsHygieneTests` hold that line).
///
/// The reason is that a suite's file in `~/Library/Preferences` cannot be
/// removed from inside the process that wrote it. `removePersistentDomain(forName:)`
/// empties the domain but leaves `<name>.plist` behind, and deleting the file
/// does not hold: `cfprefsd` keeps the emptied domain and writes it back out
/// about five seconds later, after the writing process has already exited.
/// Measured, with the suite written to and then removed:
///
/// | checked at     | plain | + `CFPreferencesAppSynchronize` | + `removeSuite` |
/// | -------------- | ----- | ------------------------------- | --------------- |
/// | immediately    | gone  | gone                            | gone            |
/// | 2 s            | gone  | gone                            | gone            |
/// | 5 s and beyond | back  | back                            | back            |
///
/// Unlinking those files from a later run bounded the pile but never emptied it.
///
/// A suite name that is an absolute path sidesteps all of it. CFPreferences
/// treats such a name as the location of the domain's file, so the suite reads
/// and writes `<path>.plist` and `cfprefsd`'s write-back lands there too, in a
/// folder nothing else uses. Measured: a suite opened by path wrote its file in
/// the given folder, read back through a second instance, emptied on
/// `removePersistentDomain(forName:)` like any other, and put nothing in
/// `~/Library/Preferences`.
///
/// The folders themselves still outlive their process for the same five
/// seconds, so a later run deletes them; see `sweepProcessesThatHaveExited()`.
/// The temporary directory is also purged by the system, so a folder a sweep
/// misses is not kept for good either.
enum DefaultsSuite {
    /// A scratch suite for `name`, backed by a file in this process's folder.
    ///
    /// - Parameter name: a name the caller minted, unique per suite, such as
    ///   `"AppSettingsTests-\(getpid())-\(UUID().uuidString)"`. Hand the same
    ///   name to `remove(_:)` when the test is done with it.
    static func open(_ name: String) -> UserDefaults? {
        UserDefaults(suiteName: domain(name))
    }

    /// The domain `open(_:)` uses for `name`, for code under test that takes a
    /// domain name rather than a `UserDefaults`.
    static func domain(_ name: String) -> String {
        // A name with a slash in it would reach outside this process's folder.
        precondition(
            name.wholeMatch(of: plainName) != nil,
            "Not a plain scratch suite name: \(name)",
        )
        return processDirectory.appendingPathComponent(name).path
    }

    /// Empty the suite's domain, so the next test that reuses the name, or reads
    /// the same file, starts from nothing.
    ///
    /// The file stays until a later run deletes this process's folder; see the
    /// type's documentation for why it cannot go now.
    static func remove(_ name: String) {
        UserDefaults().removePersistentDomain(forName: domain(name))
    }

    nonisolated(unsafe) private static let plainName = /[A-Za-z0-9][A-Za-z0-9._-]*/

    // MARK: - Folders

    /// Where every test process keeps its suites, one folder per process. Under the
    /// temporary directory rather than the account's home: it is per user, it is
    /// not moved by `CFFIXED_USER_HOME`, so every run on the account sweeps the
    /// same folders, and the system purges it on its own.
    static let rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("MeetingTranscriberTests-defaults", isDirectory: true)

    /// This process's folder, created the first time a suite is named. A
    /// `static let` initialiser runs exactly once, so this needs no flag or lock.
    ///
    /// Named `<pid>-<UUID>` rather than after the pid alone. A `--parallel` run
    /// starts thousands of processes, so pids come round again, and a new
    /// process that took over a dead one's folder could have it deleted by a
    /// sweep that had already judged the old owner gone. A folder of its own
    /// can only be swept once this process has exited.
    ///
    /// The sweep of older runs starts here too, on a background queue: it can
    /// list a large preferences folder, and the first suite is usually named
    /// inside a test, often on the main actor.
    static let processDirectory: URL = {
        let dir = rootDirectory.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The settling clock should start when this process is done, not when
        // it last wrote a suite; see `sweepProcessesThatHaveExited`. A crash
        // skips this and falls back to the last write.
        // A C function pointer cannot capture `Self`, so the type is named.
        // swiftlint:disable:next prefer_self_in_static_references
        atexit { DefaultsSuite.finishProcess() }
        sweep.enter()
        DispatchQueue.global(qos: .utility).async {
            sweepIfDue()
            sweep.leave()
        }
        return dir
    }()

    /// The background sweep, so exit can wait for it: under `--parallel` the
    /// process that wins the claim usually runs a test of a few milliseconds,
    /// and a sweep cut off at exit would leave the period's work undone while
    /// its claim kept everyone else from doing it.
    private static let sweep = DispatchGroup()

    /// Waits for the sweep, bounded so a stuck file system cannot hold the exit
    /// for long (a sweep that runs over is finished by a later one), then
    /// touches this process's folder.
    private static func finishProcess() {
        _ = sweep.wait(timeout: .now() + 10)
        utimes(processDirectory.path, nil)
    }

    /// Sweeps older runs, at most once per `settlingSeconds` across all
    /// processes. Under `--parallel` every test is a process of its own, and a
    /// sweep per process would list and probe every sibling's folder thousands
    /// of times per run while deleting nothing, since no folder settles sooner.
    private static func sweepIfDue() {
        guard claimSweep() else { return }
        sweepProcessesThatHaveExited()
        sweepRunsThatHaveExited()
        sweepDeadFactoryFiles()
    }

    /// Whether this process won the sweep for the current period. The claim is a
    /// file created with `O_EXCL`, so of the workers a `--parallel` run starts at
    /// once exactly one gets it; its age is the time since the last sweep.
    ///
    /// A claim older than `settlingSeconds` is renamed aside first, which only
    /// one process can do. A process that read the old claim's age just before
    /// another replaced it would rename the fresh one aside instead, so the
    /// moved file's age is checked again and a fresh claim goes back, but only
    /// onto an empty path (`RENAME_EXCL`), never over a claim made meanwhile.
    private static func claimSweep() -> Bool {
        let claim = rootDirectory.appendingPathComponent(claimName).path
        if createExclusively(claim) { return true }
        guard hasSettled(URL(fileURLWithPath: claim)) else { return false }
        let aside = "\(claim)-\(UUID().uuidString)"
        guard rename(claim, aside) == 0 else { return false }
        guard hasSettled(URL(fileURLWithPath: aside)) else {
            // Only a claim made in the gap (EEXIST) makes the moved one
            // redundant. On any other failure it stays aside, for the stray
            // cleanup to take once it has settled.
            if renamex_np(aside, claim, UInt32(RENAME_EXCL)) != 0, errno == EEXIST { unlink(aside) }
            return false
        }
        unlink(aside)
        return createExclusively(claim)
    }

    private static let claimName = ".sweep-claim"

    private static func createExclusively(_ path: String) -> Bool {
        let descriptor = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// How long a folder has to sit untouched before it may be deleted.
    ///
    /// A dead pid is not enough on its own. `cfprefsd` writes a removed domain's
    /// file back about five seconds after the owning process exits, and a sweep
    /// before then has the file recreated behind it. Sweeping on a dead pid alone
    /// was measured to leave hundreds of files per run. A late deletion does hold.
    ///
    /// A minute is far more than the five seconds observed, and costs only that
    /// a run started immediately after another leaves the older one's folders
    /// for the run after that.
    private static let settlingSeconds: TimeInterval = 60

    /// Delete the folder of every test process that is gone and whose folder has
    /// settled. Nothing here fails a test: a folder that cannot be deleted only
    /// waits for the next run, or for the system's purge of the temporary
    /// directory.
    private static func sweepProcessesThatHaveExited() {
        let root = rootDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries {
            // A claim moved aside by a process that died before unlinking it.
            if entry.hasPrefix(claimName + "-") {
                let stray = root.appendingPathComponent(entry)
                if hasSettled(stray) { unlink(stray.path) }
                continue
            }
            // This process's own folder is never a candidate, though the sweep
            // runs inside it: its pid is alive. Said explicitly all the same.
            guard let owner = pid_t(entry.prefix { $0 != "-" }), owner > 0, owner != getpid(),
                  processHasExited(owner)
            else { continue }
            let dir = root.appendingPathComponent(entry, isDirectory: true)
            // The folder's date is touched when its owner exits, and moves again
            // whenever `cfprefsd` writes a file into it, so a minute of quiet
            // here is a minute since both. A process that crashed skipped the
            // touch; its folder dates from its last write, and at worst is
            // recreated by the write-back for the next sweep to take.
            guard hasSettled(dir) else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func hasSettled(_ item: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
        guard let written = attributes?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(written) > settlingSeconds
    }

    /// Whether no process holds this pid.
    ///
    /// `kill(pid, 0) != 0` alone means "not signalable", which is not the same
    /// thing: a live process owned by another user answers `EPERM`, and reading
    /// that as gone would have this delete files a running test still owns.
    /// Proven reachable by planting a file named after pid 1.
    static func processHasExited(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    // MARK: - Files left in ~/Library/Preferences by earlier runs

    // Everything below drains what runs before the move to path-named suites
    // left behind: suites named plainly, whose files sit in the account's
    // preferences, listed by those runs in one manifest per process, plus the
    // `WatchingControllerFactory-<pid>` files that factory left before it kept
    // manifests. Nothing writes either any more, so once the last one is swept
    // on a machine, this has nothing left to do and can go.
    //
    // Unlink only, never `removePersistentDomain` first: emptying the domain
    // here is a write, and `cfprefsd` would put the file back once this
    // process exits, every run.

    /// Unlink the factory's per-process files whose owner is gone. This lists
    /// the preferences folder, which is large on a machine that has run the
    /// suite for a while, so it runs only under `sweepIfDue`.
    private static func sweepDeadFactoryFiles() {
        let prefix = "WatchingControllerFactory-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferencesDirectory.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".plist") {
            let stem = name.dropLast(".plist".count)
            // The pid is the first component after the prefix, which also
            // matches the older `<pid>-<uuid>` names.
            guard let owner = pid_t(stem.dropFirst(prefix.count).prefix { $0 != "-" }), owner > 0,
                  processHasExited(owner),
                  hasSettled(preferencesDirectory.appendingPathComponent(name))
            else { continue }
            unlinkSuiteFile(named: String(stem))
        }
    }

    private static let manifestDirectory = accountHome
        .appendingPathComponent("Library/Caches/MeetingTranscriber/test-defaults-suites")

    /// Where a plainly named suite's backing plist lives.
    static let preferencesDirectory = accountHome.appendingPathComponent("Library/Preferences")

    /// The account's home from the user database. Not `homeDirectoryForCurrentUser`:
    /// under `CFFIXED_USER_HOME`, which the self-hosted CI lanes set, that names the
    /// redirected home while `cfprefsd` keeps writing plainly named suites into this one.
    static let accountHome: URL = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }()

    /// Unlink every suite file listed by a settled manifest whose process is
    /// gone, then drop the manifest. Same settling rule as the folders above.
    private static func sweepRunsThatHaveExited() {
        let dir = manifestDirectory
        let manifests = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for manifest in manifests where manifest.hasSuffix(".txt") {
            let owner = pid_t(manifest.dropLast(".txt".count)) ?? 0
            guard owner > 0, processHasExited(owner) else { continue }
            let file = dir.appendingPathComponent(manifest)
            guard hasSettled(file) else { continue }
            let listed = (try? String(contentsOf: file, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            var allGone = true
            for name in listed where !unlinkSuiteFile(named: name) {
                allGone = false
            }
            // Only once there is nothing left to remember. Dropping the manifest
            // while a file survives would throw away the only record that it
            // needs removing, and no later run could find it again.
            guard allGone else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Unlinks the file; true if it is gone or never existed.
    @discardableResult
    private static func unlinkSuiteFile(named name: String) -> Bool {
        // A refused name is not gone: its manifest stays rather than recording
        // a file this helper will not touch as cleaned up.
        guard let file = suiteFile(named: name) else { return false }
        return unlink(file.path) == 0 || errno == ENOENT
    }

    /// The plist for `name`, or nil unless `name` is shaped like a scratch suite.
    /// The folder is the account's real preferences, and the names come back from
    /// manifests on disk, so a damaged or planted manifest must not be able to
    /// name `.GlobalPreferences` or a real application's domain. A scratch name is
    /// the shape the tests mint: a dash-separated identifier (the test class,
    /// maybe a qualifier), an optional pid, and a UUID, as in
    /// `AppSettingsTests-<pid>-<UUID>` or `WatchSlackTests.<pid>.<UUID>`. A UUID
    /// tail alone is not enough: `com.example.app.<UUID>` is refused. The one
    /// name without a UUID is `WatchingControllerFactory-<pid>`.
    static func suiteFile(named name: String) -> URL? {
        guard name.wholeMatch(of: scratchName) != nil || name.wholeMatch(of: factoryName) != nil else {
            return nil
        }
        return preferencesDirectory.appendingPathComponent("\(name).plist")
    }

    nonisolated(unsafe) private static let scratchName =
        /[A-Za-z][A-Za-z0-9]*(-[A-Za-z0-9]+)*[-.]([0-9]+[-.])?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
    nonisolated(unsafe) private static let factoryName = /WatchingControllerFactory-[0-9]+/
}
