import Foundation
import XCTest

// Helpers for tests that run fake `/bin/sh` executables in place of a real
// subprocess and check what became of them.

/// The first line of `file`, trimmed, or `nil` while the file is missing or
/// empty, for values a fake process writes out (its pid, a path it got).
func readFirstLine(of file: URL) -> String? {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
}

/// The pid a fake process wrote to `file`, or `nil` before it has.
func readPID(_ file: URL) -> pid_t? {
    readFirstLine(of: file).flatMap { pid_t($0) }
}

/// A fake process, or a process a fake starts, that runs until the test
/// releases it, for verdicts that would otherwise rest on time: code that
/// must not wait for it returns while it still runs, so no tight bound is
/// needed. The test releases it by removing the folder it was made in, as
/// the folder's teardown does, so it ends within a tenth of a second
/// however the test went. Broken code that waits for it is caught by the
/// safety net: after `safetyNet` seconds it gives up, leaving `expired`
/// before it exits and so before it closes what it holds, and whoever saw
/// it go sees the file. A file, not `kill(pid, 0)`: that also answers for a
/// process just exited and not yet reaped, at exactly that moment.
struct HeldFake {
    /// How long it runs before it gives up, on the wall clock: far past any
    /// correct run, so only broken code under test ever waits that long.
    static let safetyNet = 30
    /// For limits not under test (a timeout, a drain grace that nothing
    /// should end early): past `safetyNet`, so they cannot end a run first.
    static let noLimit = TimeInterval(2 * safetyNet)
    /// A coarse ceiling on stopping a process, SIGTERM then SIGKILL a short
    /// grace later, for tests of a genuine time limit; not a speed check.
    static let stopBound: TimeInterval = 10

    /// The executable, for a fake to `exec` and so be the held process.
    let path: String
    let expired: URL
    /// Written as the first thing it does.
    let started: URL

    /// Shell lines that wait until it has started. A fake that starts it in
    /// the background runs these before going on, so nothing the fake does
    /// next (exiting, being stopped, having its working directory removed)
    /// can end it before it holds anything; it would then pass the test
    /// without testing it.
    var waitForStart: String {
        "while [ ! -e '\(started.path)' ]; do sleep 0.01; done"
    }

    /// Shell lines that start it in the background, holding the pipes the
    /// fake has, and wait until it has started.
    var inBackground: String {
        "'\(path)' &\n\(waitForStart)"
    }

    func assertNotRunOut(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path), message, file: file, line: line)
    }

    /// It was stopped rather than left to give up, and the code under test
    /// returned within `stopBound` of `start`.
    func assertStopped(
        since start: Date, _ message: String, file: StaticString = #filePath, line: UInt = #line,
    ) {
        assertNotRunOut(message, file: file, line: line)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), Self.stopBound, "the run ended past the ceiling", file: file, line: line,
        )
    }
}

extension XCTestCase {
    /// A `HeldFake` named `name`, released when `folder` is removed.
    func makeHeldFake(in folder: URL, name: String) throws -> HeldFake {
        let held = folder.appendingPathComponent("\(name).held")
        let expired = folder.appendingPathComponent("\(name).expired")
        let started = folder.appendingPathComponent("\(name).started")
        try Data().write(to: held)
        let path = try makeExecutableScript(in: folder, name: "\(name).sh", body: """
        touch '\(started.path)'
        end=$(($(date +%s) + \(HeldFake.safetyNet)))
        while [ -e '\(held.path)' ] && [ "$(date +%s)" -lt "$end" ]; do
          sleep 0.1
        done
        if [ -e '\(held.path)' ]; then touch '\(expired.path)'; fi
        """)
        return HeldFake(path: path, expired: expired, started: started)
    }

    /// Writes `body` as an executable `/bin/sh` script named `name` in
    /// `folder` and returns its path.
    func makeExecutableScript(in folder: URL, name: String, body: String) throws -> String {
        let path = folder.appendingPathComponent(name).path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Waits, for up to five seconds, for a fake to have written its pid to
    /// `pidFile`, which it does once it has got as far as the test needs it
    /// to be before acting on it. The pid itself, not the file: the shell
    /// creates the file before it writes, and a fake stopped in between
    /// leaves one that is empty. Gives up rather than failing, since a fake
    /// that never started leaves nothing to read, which the assertion on it
    /// then reports. For suites off the main actor, where `waitFor` is not
    /// callable.
    func waitForPID(pidFile: URL) async throws {
        let writtenBy = Date().addingTimeInterval(5)
        while readPID(pidFile) == nil, Date() < writtenBy {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The process whose pid `pidFile` holds has exited and been reaped.
    func assertProcessGone(pidFile: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pid = try XCTUnwrap(readPID(pidFile), "the fake process never started", file: file, line: line)
        let result = kill(pid, 0)
        let code = errno
        XCTAssertEqual(result, -1, "the process is still running", file: file, line: line)
        XCTAssertEqual(code, ESRCH, file: file, line: line)
    }
}
