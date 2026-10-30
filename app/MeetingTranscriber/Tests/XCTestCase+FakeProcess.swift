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

extension XCTestCase {
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
