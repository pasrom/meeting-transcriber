@testable import MeetingTranscriber
import XCTest

/// The processes these tests stop are `HeldFake`s, judged by their marker.
final class BoundedProcessTests: XCTestCase {
    func testRunReturnsTheExitStatus() async throws {
        let process = Self.shell("exit 3")

        let outcome = try await BoundedProcess(process).run(timeout: HeldFake.noLimit)

        XCTAssertEqual(outcome, .exited(3))
    }

    /// A process that ignores SIGTERM is killed once the grace period has
    /// passed, and the run reports the timeout only after it has exited. The
    /// limit must pass after the trap is set.
    func testRunKillsAProcessThatIgnoresSIGTERMAtTheTimeout() async throws {
        let (process, held) = try heldShellIgnoringSIGTERM()

        let outcome = try await passLimit(of: held, "the process was not killed") { clock, timeout in
            try await BoundedProcess(process, terminationGrace: 0.15, clock: clock).run(timeout: timeout)
        }.get()

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(process.isRunning, "the run returned before the process had exited")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    /// Cancelling stops the process, and the run still returns only once it
    /// has exited. The process ignores SIGTERM, so it outlives the
    /// cancellation by the grace period; it starts after the trap is set,
    /// so the cancel cannot come before it.
    func testCancellingRunStopsTheProcessAndWaitsForItsExit() async throws {
        let (process, held) = try heldShellIgnoringSIGTERM()
        let run = Task { try await BoundedProcess(process, terminationGrace: 0.15).run(timeout: HeldFake.noLimit) }
        defer { run.cancel() }
        try await waitForStart(of: held)
        let start = Date()

        run.cancel()
        let result = await run.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        XCTAssertFalse(process.isRunning, "the run returned before the process had exited")
        held.assertStopped(since: start, "the process was not stopped")
    }

    /// A whole number of seconds is shown without a fraction.
    func testLabelShowsAFractionOnlyWhenThereIsOne() {
        XCTAssertEqual(BoundedProcess.label(for: 300), "300")
        XCTAssertEqual(BoundedProcess.label(for: 0.2), "0.2")
    }

    /// A shell that ignores SIGTERM and then becomes a `HeldFake`, which
    /// keeps ignoring it and has the shell's pid. It starts once the trap is
    /// set, so a test can wait for that before signalling it.
    private func heldShellIgnoringSIGTERM() throws -> (process: Process, held: HeldFake) {
        let held = try makeHeldFake(in: makeTempDirectory(prefix: "bounded-process"), name: "held")
        return (Self.shell("trap '' TERM; exec '\(held.path)'"), held)
    }

    private static func shell(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return process
    }
}
