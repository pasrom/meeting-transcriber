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

/// The process whose pid `pidFile` holds has exited and been reaped. Only
/// for a process known to have been waited for: an exited one not yet
/// reaped still answers `kill(pid, 0)`.
func assertProcessGone(pidFile: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let pid = try XCTUnwrap(readPID(pidFile), "the fake process never started", file: file, line: line)
    let result = kill(pid, 0)
    let code = errno
    XCTAssertEqual(result, -1, "the process is still running", file: file, line: line)
    XCTAssertEqual(code, ESRCH, file: file, line: line)
}

/// A fake process, or a process a fake starts, that runs until the test
/// releases it, for verdicts that would otherwise rest on time: code that
/// must not wait for it returns while it still runs, so no tight bound is
/// needed. The test releases it by removing the folder it was made in, as
/// the folder's teardown does, so it ends within a tenth of a second
/// however the test went. Broken code that waits for it is caught by the
/// safety net: after `safetyNet` seconds it gives up, leaving `expired`
/// before it exits and so before it closes what it holds, and whoever saw
/// it go sees the file. Whether it gave up is read from that file, not from
/// `kill(pid, 0)`: that also answers for a process just exited and not yet
/// reaped, at exactly that moment.
///
/// As it starts it writes its pid to `pidFile` and then `started`, so
/// either one there means everything a fake set up before it is done.
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
    /// How often a fake checks whether it has started.
    private static let startPoll: TimeInterval = 0.05

    /// The executable, for a fake to `exec` and so be the held process.
    let path: String
    let pidFile: URL
    let expired: URL
    let started: URL
    /// Left by a fake that gave up waiting for it to start.
    let startFailed: URL

    /// Shell lines that wait, for `stopBound` at least, until it has
    /// started. A fake that starts it in the background runs these before
    /// going on, so nothing the fake does next (exiting, being stopped,
    /// having its working directory removed) can end it before it holds
    /// anything; it would then pass the test without testing it. A fake that
    /// waited in vain leaves `startFailed` and goes on, for
    /// `assertNotRunOut` to report.
    var waitForStart: String {
        let polls = Int(Self.stopBound / Self.startPoll)
        return """
        n=0
        while [ ! -e '\(started.path)' ] && [ $n -lt \(polls) ]; do sleep \(Self.startPoll); n=$((n + 1)); done
        [ -e '\(started.path)' ] || touch '\(startFailed.path)'
        """
    }

    /// Shell lines that start it in the background, holding the pipes the
    /// fake has, and wait until it has started.
    var inBackground: String {
        "'\(path)' &\n\(waitForStart)"
    }

    /// It started in time and had not given up when this is called.
    func assertNotRunOut(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        XCTAssertTrue(exists(started), "the held child never started", file: file, line: line)
        XCTAssertFalse(exists(startFailed), "the held child did not start in time", file: file, line: line)
        XCTAssertFalse(exists(expired), message, file: file, line: line)
    }

    /// It was stopped rather than left to give up, has exited and been
    /// reaped, and the code under test returned within `stopBound` of
    /// `start`. For code that waits for the process to exit before it
    /// returns, so that the process being gone is a fair check.
    func assertStopped(
        since start: Date, _ message: String, file: StaticString = #filePath, line: UInt = #line,
    ) {
        assertNotRunOut(message, file: file, line: line)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), Self.stopBound, "the run ended past the ceiling", file: file, line: line,
        )
        try? assertProcessGone(pidFile: pidFile, file: file, line: line)
    }
}

/// `waitForPID` ran out.
struct PIDNotWritten: Error, CustomStringConvertible {
    let pidFile: URL

    var description: String {
        "no pid in \(pidFile.lastPathComponent) after \(Int(HeldFake.noLimit)) s: the fake never got that far"
    }
}

extension XCTestCase {
    /// A `HeldFake` named `name`, released when `folder` is removed. The
    /// polling is perl's, not the shell's, so it forks nothing while it
    /// waits, and its deadline is taken once.
    func makeHeldFake(in folder: URL, name: String) throws -> HeldFake {
        let file = { (suffix: String) in folder.appendingPathComponent("\(name).\(suffix)") }
        let (pidFile, started, held, expired) = (file("pid"), file("started"), file("held"), file("expired"))
        try Data().write(to: held)
        let path = try makeExecutableScript(in: folder, name: "\(name).sh", body: """
        exec /usr/bin/perl -e '
          my ($pidFile, $started, $held, $expired) = @ARGV;
          my ($f, $pid) = (undef, $$);
          open($f, ">", $pidFile) and print($f $pid) and close($f);
          open($f, ">", $started) and close($f);
          my $end = time() + \(HeldFake.safetyNet);
          select(undef, undef, undef, 0.1) while -e $held && time() < $end;
          if (-e $held) { open($f, ">", $expired) and close($f); }
        ' '\(pidFile.path)' '\(started.path)' '\(held.path)' '\(expired.path)'
        """)
        return HeldFake(
            path: path, pidFile: pidFile, expired: expired, started: started, startFailed: file("start-failed"),
        )
    }

    /// Writes `body` as an executable `/bin/sh` script named `name` in
    /// `folder` and returns its path.
    func makeExecutableScript(in folder: URL, name: String, body: String) throws -> String {
        let path = folder.appendingPathComponent(name).path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Waits for a fake to have written its pid to `pidFile`, which it does
    /// once it has got as far as the test needs it to be before acting on
    /// it. The pid itself, not the file: the shell creates the file before
    /// it writes, and a fake stopped in between leaves one that is empty.
    /// The bound is generous, `HeldFake.noLimit`, because a fake may have
    /// work to do first on a loaded runner; running out throws, so a test
    /// never acts on a fake that is not there yet. For suites off the main
    /// actor, where `waitFor` is not callable.
    func waitForPID(pidFile: URL) async throws {
        let writtenBy = Date().addingTimeInterval(HeldFake.noLimit)
        while readPID(pidFile) == nil {
            guard Date() < writtenBy else { throw PIDNotWritten(pidFile: pidFile) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
