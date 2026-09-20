import Foundation

/// Cleanup for the scratch `UserDefaults` suites tests make.
///
/// The obvious teardown does not work, and neither does any variation on it that
/// runs inside the test process. This is worth reading before trying to simplify
/// what follows, because every shorter version was measured and failed.
///
/// `removePersistentDomain(forName:)` empties the domain but leaves
/// `~/Library/Preferences/<name>.plist` behind, so a suite per test adds a file
/// to that directory on every run and never takes one away. Deleting the file
/// afterwards does not hold: `cfprefsd` keeps the emptied domain and writes it
/// back out about five seconds later. Measured, with the suite written to and
/// then removed:
///
/// | checked at     | plain | + `CFPreferencesAppSynchronize` | + `removeSuite` |
/// | -------------- | ----- | ------------------------------- | --------------- |
/// | immediately    | gone  | gone                            | gone            |
/// | 2 s            | gone  | gone                            | gone            |
/// | 5 s and beyond | back  | back                            | back            |
///
/// Forcing the flush first does not help, taking the suite out of the search
/// list does not help, and an `atexit` unlink does not help either: the rewrite
/// lands roughly five seconds after the writing process has already exited, so
/// there is no moment inside the process's life at which the file can be deleted
/// and stay deleted.
///
/// That timing is also why a short run looks clean whatever the teardown does. A
/// `swift test --filter OneClass` process is gone long before the rewrite, and a
/// check made right after it exits reads "clean" and means nothing. Across a
/// full suite the leak lands somewhere between a quarter and three quarters of
/// the suites created, varying per run, because each one is a race.
///
/// So the cleanup is deferred to a later run, which is what
/// `WatchingControllerFactory` already does for its own files and the reason its
/// prefix is the one that has not piled up: 20 files against 34,863 for a test
/// class with no sweep.
///
/// The difference here is how the files are found. That sweep lists
/// `~/Library/Preferences`, which holds a six-figure number of entries on a
/// machine that has run this suite for a while, and its own comment records
/// paying 16 s across the suite for listing it per call. This records the names
/// it created in a manifest instead, so a later run unlinks exactly those names
/// and never reads the preferences directory at all.
enum DefaultsSuite {
    /// Empty the suite's domain, and note its file for a later run to unlink.
    ///
    /// The domain is emptied immediately, because that is what isolates the next
    /// test from this one's keys, and it is the only half that can take effect
    /// now. The file itself outlives this process by design; see the type's
    /// documentation.
    ///
    /// - Parameter name: a suite name the caller minted, as passed to
    ///   `UserDefaults(suiteName:)`. Not a domain owned by a real application:
    ///   a later run deletes the file that name maps to.
    static func remove(_ name: String) {
        UserDefaults().removePersistentDomain(forName: name)

        _ = sweepOnce
        record(name)
    }

    /// Sweeps older runs the first time anything is removed. A `static let` is
    /// the once-per-process guarantee, so this needs no flag and no lock.
    private static let sweepOnce: Void = sweepRunsThatHaveExited()

    /// Empty the domain and unlink the file now, for a suite whose owning
    /// process exited long enough ago that `cfprefsd` has finished with it.
    ///
    /// Correct only under that condition, which in practice means a process that
    /// exited longer ago than `manifestSettlingSeconds`; the measurement behind
    /// that is recorded there. Never for a suite this process just wrote, which
    /// is what `remove(_:)` is for.
    static func removeSettled(_ name: String) {
        UserDefaults().removePersistentDomain(forName: name)
        _ = unlinkSuiteFile(named: name)
    }

    // MARK: - Manifests

    /// One file per test process, named after its pid, listing the suites that
    /// process created. Kept outside `~/Library/Preferences` so nothing here has
    /// to read that directory, and under Caches because losing it costs a sweep
    /// rather than correctness.
    private static let manifestDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/MeetingTranscriber/test-defaults-suites")

    /// Where a suite's backing plist lives. The one place that answers this, so
    /// the sweep and the unlink cannot come to disagree about it.
    static let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences")

    /// Appends one line to this process's manifest.
    ///
    /// Serialised, because `seekToEnd` and `write` are two steps on a shared
    /// handle and tests reach this from teardown blocks on arbitrary threads.
    /// The lock covers only this: the sweep is a `static let` initialiser, which
    /// the language already runs exactly once.
    private static func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        let dir = manifestDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = dir.appendingPathComponent("\(getpid()).txt")
        let line = Data("\(name)\n".utf8)
        guard let handle = try? FileHandle(forWritingTo: manifest) else {
            try? line.write(to: manifest)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private static let lock = NSLock()

    /// How long a manifest has to sit untouched before its files may be
    /// unlinked.
    ///
    /// A dead pid is not enough on its own, and getting this wrong is worse than
    /// not sweeping at all. `cfprefsd` rewrites a removed domain's file about
    /// five seconds after the owning process exits, so an unlink before then is
    /// undone, and dropping the manifest afterwards throws away the record of
    /// which files still need removing. Measured: sweeping on a dead pid alone
    /// left 404 files across two full runs and consumed nearly every manifest
    /// inside the run that wrote it, because `--parallel` workers exit while
    /// their siblings are still starting. A late unlink does hold: a file
    /// deleted once the rewrite had already landed stayed gone.
    ///
    /// A minute is far more than the five seconds observed, and costs only that
    /// a run started immediately after another leaves the older one's files for
    /// the run after that.
    private static let manifestSettlingSeconds: TimeInterval = 60

    /// Unlink every suite file listed by a settled manifest whose process is
    /// gone, then drop the manifest. A manifest for a live process is left
    /// alone, as is one that has been written to too recently; see
    /// `manifestSettlingSeconds`.
    ///
    /// Runs once per process. Nothing here fails a test: a manifest that cannot
    /// be read or a file that cannot be deleted only means one more run carries
    /// it, which is the same state the suite was in before any of this existed.
    private static func sweepRunsThatHaveExited() {
        let dir = manifestDirectory
        let manifests = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for manifest in manifests where manifest.hasSuffix(".txt") {
            let owner = pid_t(manifest.dropLast(".txt".count)) ?? 0
            guard owner > 0, owner != getpid(), processHasExited(owner) else { continue }
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

    private static func hasSettled(_ manifest: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: manifest.path)
        guard let written = attributes?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(written) > manifestSettlingSeconds
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

    /// Removes the file and says whether it is gone, which the removal already
    /// knows. True also when it never existed, since that is the same outcome.
    @discardableResult
    private static func unlinkSuiteFile(named name: String) -> Bool {
        guard let file = suiteFile(named: name) else { return true }
        return unlink(file.path) == 0 || errno == ENOENT
    }

    private static func suiteFile(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return preferencesDirectory.appendingPathComponent("\(name).plist")
    }
}
