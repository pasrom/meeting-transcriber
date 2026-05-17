@testable import MeetingTranscriber
import XCTest

final class PersistentDiagnosticLogTests: XCTestCase {
    // MARK: - RestartPolicy

    func test_restartPolicy_emptyHistory_restartsImmediately() {
        let policy = RestartPolicy(maxFailuresInWindow: 5, window: 60, maxBackoff: 30)
        let now = Date()
        XCTAssertEqual(policy.decide(now: now, recentFailures: []), .restart(after: 1))
    }

    func test_restartPolicy_oneRecentFailure_doublesBackoff() {
        let policy = RestartPolicy(maxFailuresInWindow: 5, window: 60, maxBackoff: 30)
        let now = Date()
        let recent = [now.addingTimeInterval(-5)]
        XCTAssertEqual(policy.decide(now: now, recentFailures: recent), .restart(after: 2))
    }

    func test_restartPolicy_fourFailures_uses16sBackoff() {
        let policy = RestartPolicy(maxFailuresInWindow: 5, window: 60, maxBackoff: 30)
        let now = Date()
        let recent = (1 ... 4).map { now.addingTimeInterval(-Double($0)) }
        XCTAssertEqual(policy.decide(now: now, recentFailures: recent), .restart(after: 16))
    }

    func test_restartPolicy_atMaxFailures_givesUp() {
        let policy = RestartPolicy(maxFailuresInWindow: 5, window: 60, maxBackoff: 30)
        let now = Date()
        let recent = (1 ... 5).map { now.addingTimeInterval(-Double($0)) }
        XCTAssertEqual(policy.decide(now: now, recentFailures: recent), .giveUp)
    }

    func test_restartPolicy_failuresOutsideWindow_areIgnored() {
        let policy = RestartPolicy(maxFailuresInWindow: 5, window: 60, maxBackoff: 30)
        let now = Date()
        let stale = (1 ... 10).map { now.addingTimeInterval(-Double($0) - 60) }
        XCTAssertEqual(policy.decide(now: now, recentFailures: stale), .restart(after: 1))
    }

    func test_restartPolicy_backoffCappedAtMaxBackoff() {
        let policy = RestartPolicy(maxFailuresInWindow: 100, window: 60, maxBackoff: 5)
        let now = Date()
        let recent = (1 ... 10).map { now.addingTimeInterval(-Double($0)) }
        XCTAssertEqual(policy.decide(now: now, recentFailures: recent), .restart(after: 5))
    }

    // MARK: - Static helpers

    func test_logFileName_isYYYYMMDD() {
        let date = ISO8601DateFormatter().date(from: "2026-05-04T12:00:00Z") ?? Date()
        XCTAssertEqual(
            PersistentDiagnosticLog.logFileName(for: date),
            "diagnostics-2026-05-04.log",
        )
    }

    func test_isExpired_olderThan30Days_returnsTrue() {
        let cutoff = Date().addingTimeInterval(-31 * 86400)
        XCTAssertTrue(PersistentDiagnosticLog.isExpired(modifiedAt: cutoff, retentionDays: 30))
    }

    func test_isExpired_youngerThan30Days_returnsFalse() {
        let recent = Date().addingTimeInterval(-15 * 86400)
        XCTAssertFalse(PersistentDiagnosticLog.isExpired(modifiedAt: recent, retentionDays: 30))
    }

    func test_isExpired_atBoundary_returnsTrue() {
        let edge = Date().addingTimeInterval(-30 * 86400 - 1)
        XCTAssertTrue(PersistentDiagnosticLog.isExpired(modifiedAt: edge, retentionDays: 30))
    }

    func test_isOurLogFile_matchesExpectedPattern() {
        XCTAssertTrue(PersistentDiagnosticLog.isOurLogFile("diagnostics-2026-05-04.log"))
        XCTAssertTrue(PersistentDiagnosticLog.isOurLogFile("diagnostics-2026-12-31.log"))
    }

    func test_isOurLogFile_rejectsForeignNames() {
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("readme.md"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("diagnostics-bad.log"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("diagnostics-26-05-04.log"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("diagnostics-2026-05-04.txt"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile(""))
    }

    // MARK: - cleanup

    func test_cleanup_removesExpiredFiles_keepsRecentOnes_doesNotTouchOthers() throws {
        let tmp = try makeTempDirectory(prefix: "PersistentDiagnosticLogTests")

        let expiredFile = tmp.appendingPathComponent("diagnostics-2026-04-01.log")
        let recentFile = tmp.appendingPathComponent("diagnostics-2026-05-01.log")
        let foreign = tmp.appendingPathComponent("readme.md")

        try "old".write(to: expiredFile, atomically: true, encoding: .utf8)
        try "new".write(to: recentFile, atomically: true, encoding: .utf8)
        try "huh".write(to: foreign, atomically: true, encoding: .utf8)

        let oldDate = Date().addingTimeInterval(-31 * 86400)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: expiredFile.path,
        )
        // Backdate foreign file too — cleanup must still leave it alone.
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: foreign.path,
        )

        PersistentDiagnosticLog.cleanup(in: tmp, retentionDays: 30)

        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFile.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreign.path),
            "Cleanup must not touch non-matching files even when expired",
        )
    }

    func test_cleanup_emptyDirectory_doesNotCrash() throws {
        let tmp = try makeTempDirectory(prefix: "PersistentDiagnosticLogTests-empty")
        PersistentDiagnosticLog.cleanup(in: tmp, retentionDays: 30)
    }

    func test_cleanup_missingDirectory_doesNotCrash() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentDiagnosticLogTests-missing-\(UUID().uuidString)")
        PersistentDiagnosticLog.cleanup(in: bogus, retentionDays: 30)
    }

    // MARK: - Streamer day-rotation

    #if !APPSTORE
        func test_streamer_rotatesToNewFileWhenDayChanges() throws {
            let tmp = try makeTempDirectory(prefix: "StreamerRotation")

            var clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-04T23:59:50Z"),
            )
            let streamer = try PersistentDiagnosticLog.Streamer(logDirectory: tmp) { clock }

            streamer.append(Data("before-midnight\n".utf8))

            clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-05T00:00:10Z"),
            )
            streamer.append(Data("after-midnight\n".utf8))

            let day1 = tmp.appendingPathComponent("diagnostics-2026-05-04.log")
            let day2 = tmp.appendingPathComponent("diagnostics-2026-05-05.log")

            XCTAssertEqual(try String(contentsOf: day1), "before-midnight\n")
            XCTAssertEqual(try String(contentsOf: day2), "after-midnight\n")
        }

        func test_streamer_keepsSameFileWhenDayUnchanged() throws {
            let tmp = try makeTempDirectory(prefix: "StreamerRotation")

            var clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-04T08:00:00Z"),
            )
            let streamer = try PersistentDiagnosticLog.Streamer(logDirectory: tmp) { clock }

            streamer.append(Data("a\n".utf8))
            clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-04T20:00:00Z"),
            )
            streamer.append(Data("b\n".utf8))

            let day1 = tmp.appendingPathComponent("diagnostics-2026-05-04.log")
            XCTAssertEqual(try String(contentsOf: day1), "a\nb\n")
            // No second file should appear.
            let entries = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            XCTAssertEqual(entries.sorted(), ["diagnostics-2026-05-04.log"])
        }

        /// Regression guard: rotation must open the new handle BEFORE closing
        /// the old one. If the old handle is closed eagerly and the new open
        /// fails, every subsequent `append` would write to a closed FD and
        /// silently drop entries.
        func test_streamer_keepsWritingToOldFileWhenRotationOpenFails() throws {
            let tmp = try makeTempDirectory(prefix: "StreamerRotation")
            // Restore writable perms BEFORE makeTempDirectory's removal teardown
            // runs. addTeardownBlock is LIFO, so this fires first.
            addTeardownBlock {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: tmp.path,
                )
            }

            var clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-04T23:59:50Z"),
            )
            let streamer = try PersistentDiagnosticLog.Streamer(logDirectory: tmp) { clock }
            streamer.append(Data("before\n".utf8))

            // Make the directory read-only so creating tomorrow's file fails.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: tmp.path,
            )

            clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-05T00:00:10Z"),
            )
            streamer.append(Data("after\n".utf8))

            // Old file kept being writable — entry landed there, not dropped.
            let day1 = tmp.appendingPathComponent("diagnostics-2026-05-04.log")
            XCTAssertEqual(try String(contentsOf: day1), "before\nafter\n")
        }

        // MARK: - Streamer auto-restart

        /// Wait for `condition` to become true, polling every 20 ms, up to
        /// `timeout` seconds. Returns the final value. Used instead of a
        /// fixed `Thread.sleep` so the test exits as soon as the streamer's
        /// state settles instead of always paying the worst-case wait.
        private func waitForCondition(
            timeout: TimeInterval,
            _ condition: () -> Bool,
        ) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return condition()
        }

        /// `/usr/bin/false` exits immediately with status 1 — a reliable
        /// crash-stub for the auto-restart path that doesn't need a real
        /// `log` daemon. Combined with `maxBackoff = 0.01` the whole loop
        /// completes in well under a second.
        func test_streamer_givesUpAfterRepeatedUnexpectedExits() throws {
            let tmp = try makeTempDirectory(prefix: "StreamerRestart")
            let policy = RestartPolicy(
                maxFailuresInWindow: 3, window: 60, maxBackoff: 0.01,
            )
            let streamer = try PersistentDiagnosticLog.Streamer(
                logDirectory: tmp,
                restartPolicy: policy,
                logExecutable: URL(fileURLWithPath: "/usr/bin/false"),
                logArguments: [],
            )
            try streamer.start()
            // Don't assert `isRunning == true` here: `/usr/bin/false` exits in
            // microseconds and the terminationHandler's `restartQueue.async`
            // hop can flip `_isRunning = false` (via failFastWindow) before
            // the test thread's `restartQueue.sync { _isRunning }` read lands.
            // The give-up behavior is the real claim — asserted below.

            XCTAssertTrue(
                waitForCondition(timeout: 2.0) { !streamer.isRunning },
                "Streamer should have given up after 3 failures",
            )
        }

        /// macOS 26 made `log stream` admin-only — the spawn → exit-1
        /// cycle ran up to maxFailuresInWindow times and pegged 2 cores
        /// on dev builds. With the guard, an exit inside `failFastWindow`
        /// triggers an immediate give-up.
        ///
        /// Falsifiability: `maxBackoff: 60` means the un-guarded slow
        /// path would need ~60 s for the first relaunch alone — well past
        /// the 2 s assertion. Without the guard, this test fails.
        func test_streamer_failsFastOnInstantExit() throws {
            let tmp = try makeTempDirectory(prefix: "StreamerFailFast")
            let policy = RestartPolicy(
                maxFailuresInWindow: 100, window: 60, maxBackoff: 60,
            )
            let streamer = try PersistentDiagnosticLog.Streamer(
                logDirectory: tmp,
                restartPolicy: policy,
                logExecutable: URL(fileURLWithPath: "/usr/bin/false"),
                logArguments: [],
            )
            try streamer.start()
            XCTAssertTrue(
                waitForCondition(timeout: 2.0) { !streamer.isRunning },
                "Streamer should fail fast on instant exit, not wait for the slow-path backoff",
            )
        }

        /// PR #218 fail-fast stops relaunching but the pipe's readabilityHandler
        /// stays subscribed to the dead subprocess's pipe. Foundation reschedules
        /// the handler on persistent EOF — observed as ~100 % CPU on macOS 26.
        /// The handler must self-detach on first empty `availableData`.
        func test_streamer_pipeReadabilityHandlerDetachesOnSubprocessEOF() throws {
            let tmp = try makeTempDirectory(prefix: "StreamerEOFDetach")
            let policy = RestartPolicy(
                maxFailuresInWindow: 100, window: 60, maxBackoff: 60,
            )
            let streamer = try PersistentDiagnosticLog.Streamer(
                logDirectory: tmp,
                restartPolicy: policy,
                logExecutable: URL(fileURLWithPath: "/usr/bin/false"),
                logArguments: [],
            )
            try streamer.start()
            // Wait for fail-fast to fire AND the readabilityHandler to
            // self-detach. Without the fix, isRunning flips false but the
            // handler stays attached and fires forever.
            XCTAssertTrue(
                waitForCondition(timeout: 2.0) {
                    !streamer.isRunning && !streamer.hasReadabilityHandlerForTesting
                },
                "Pipe readabilityHandler must detach on EOF — otherwise it spins on an empty Data forever",
            )
        }

        /// `stop()` must short-circuit any pending relaunch; otherwise an
        /// `asyncAfter` enqueued during the restart loop could fire after
        /// the test (and the `Streamer`) is gone, writing to a freed FD.
        func test_streamer_stopDuringRestartLoopIsCleanlyTerminated() throws {
            let tmp = try makeTempDirectory(prefix: "StreamerStopMidRestart")
            let policy = RestartPolicy(
                maxFailuresInWindow: 100, window: 60, maxBackoff: 0.05,
            )
            let streamer = try PersistentDiagnosticLog.Streamer(
                logDirectory: tmp,
                restartPolicy: policy,
                logExecutable: URL(fileURLWithPath: "/usr/bin/false"),
                logArguments: [],
            )
            try streamer.start()
            // Let the restart loop iterate at least once before pulling the rug.
            Thread.sleep(forTimeInterval: 0.1)
            streamer.stop()
            XCTAssertFalse(streamer.isRunning)
            // Give any in-flight `asyncAfter` a chance to fire — it must
            // observe `isRunning == false` and bail.
            Thread.sleep(forTimeInterval: 0.2)
            XCTAssertFalse(streamer.isRunning)
        }
    #endif
}
