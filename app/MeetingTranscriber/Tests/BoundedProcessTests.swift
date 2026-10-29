@testable import MeetingTranscriber
import XCTest

final class BoundedProcessTests: XCTestCase {
    func testRunReturnsTheExitStatus() async throws {
        let process = Self.shell("exit 3")

        let outcome = try await BoundedProcess(process).run(timeout: 5)

        XCTAssertEqual(outcome, .exited(3))
    }

    /// A process that ignores SIGTERM is killed once the grace period has
    /// passed, and the run reports the timeout only after it has exited.
    func testRunKillsAProcessThatIgnoresSIGTERMAtTheTimeout() async throws {
        let process = Self.shell("trap '' TERM; exec sleep 3")
        let start = Date()

        let outcome = try await BoundedProcess(process, terminationGrace: 0.15).run(timeout: 0.2)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Cancelling stops the process, and the run still returns only once it
    /// has exited. The process ignores SIGTERM, so it outlives the
    /// cancellation by the grace period; the ready file is written after the
    /// trap is set, so the cancel cannot come before it.
    func testCancellingRunStopsTheProcessAndWaitsForItsExit() async throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let process = Self.shell("trap '' TERM; touch '\(ready.path)'; exec sleep 3")
        let run = Task { try await BoundedProcess(process, terminationGrace: 0.15).run(timeout: 30) }
        let startedBy = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < startedBy {
            try await Task.sleep(for: .milliseconds(20))
        }
        let start = Date()

        run.cancel()
        let result = await run.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        XCTAssertFalse(process.isRunning, "the run returned before the process had exited")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    private static func shell(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return process
    }
}
