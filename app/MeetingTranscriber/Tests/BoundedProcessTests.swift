@testable import MeetingTranscriber
import XCTest

final class BoundedProcessTests: XCTestCase {
    func testRunReturnsTheExitStatus() async throws {
        let process = Self.shell("exit 3")

        let outcome = try await BoundedProcess(process).run(timeout: 5)

        XCTAssertEqual(outcome, .exited(3))
    }

    /// A process that ignores SIGTERM is killed once the grace period has
    /// passed, and the run reports the timeout only after it has exited. The
    /// limit passes once the process has set its trap, which the pid written
    /// after it shows; in real time it could pass first on a loaded machine,
    /// and the SIGTERM would then end a process not yet ignoring it.
    func testRunKillsAProcessThatIgnoresSIGTERMAtTheTimeout() async throws {
        let (process, pidFile) = shellIgnoringSIGTERM()
        let timeout: TimeInterval = 0.2
        let clock = ManualClock()
        let run = Task { try await BoundedProcess(process, terminationGrace: 0.15, clock: clock).run(timeout: timeout) }
        try await waitForPID(pidFile: pidFile)
        let start = Date()

        await clock.advance(by: .seconds(timeout))
        let outcome = try await run.value

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Cancelling stops the process, and the run still returns only once it
    /// has exited. The process ignores SIGTERM, so it outlives the
    /// cancellation by the grace period; the pid is written after the trap
    /// is set, so the cancel cannot come before it.
    func testCancellingRunStopsTheProcessAndWaitsForItsExit() async throws {
        let (process, pidFile) = shellIgnoringSIGTERM()
        let run = Task { try await BoundedProcess(process, terminationGrace: 0.15).run(timeout: 30) }
        try await waitForPID(pidFile: pidFile)
        let start = Date()

        run.cancel()
        let result = await run.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        XCTAssertFalse(process.isRunning, "the run returned before the process had exited")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// A whole number of seconds is shown without a fraction.
    func testLabelShowsAFractionOnlyWhenThereIsOne() {
        XCTAssertEqual(BoundedProcess.label(for: 300), "300")
        XCTAssertEqual(BoundedProcess.label(for: 0.2), "0.2")
    }

    /// A shell that ignores SIGTERM and then sleeps, with the file it
    /// writes its pid to once the trap is set, so a test can wait for that
    /// before signalling it.
    private func shellIgnoringSIGTERM() -> (process: Process, pidFile: URL) {
        let pidFile = makeTempFile(suffix: ".pid")
        return (Self.shell("trap '' TERM; echo $$ > '\(pidFile.path)'; exec sleep 3"), pidFile)
    }

    private static func shell(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return process
    }
}
