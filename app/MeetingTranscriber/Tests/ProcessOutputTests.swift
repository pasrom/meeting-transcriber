@testable import MeetingTranscriber
import XCTest

/// No verdict rests on how fast a run was: a child holding stderr open is a
/// `HeldFake`, and limits not under test are `HeldFake.noLimit`.
final class ProcessOutputTests: XCTestCase {
    private static let grace: TimeInterval = 0.15

    // MARK: - run

    /// After a failed exit, output a process's child still holds open is
    /// ended a drain grace later and reported as cut. The app's own grace,
    /// not `grace`: a short one would race the reading of "boom" on a slow
    /// runner.
    func testRunEndsOutputAChildHoldsOpenADrainGraceAfterTheExit() async throws {
        let holder = try makeHolder()
        var reported: [Bool] = []

        let (outcome, stderr) = try await run(
            "\(holder.inBackground)\necho boom >&2; exit 3", drainGrace: ProcessOutput.defaultDrainGrace,
        ) { reported = $0 }

        XCTAssertEqual(outcome, .exited(3))
        XCTAssertEqual(String(data: stderr, encoding: .utf8), "boom\n")
        XCTAssertEqual(reported, [true])
        holder.assertNotRunOut("the output waited for the child, not for the drain grace")
    }

    /// Output that reaches end of file is not reported as cut. End of file
    /// ends the read; drain grace `HeldFake.noLimit`, so a slow reader is not cut.
    func testRunDoesNotReportOutputThatEndedByItself() async throws {
        var reported: [Bool] = []

        let (outcome, stderr) = try await run("echo boom >&2; exit 3", drainGrace: HeldFake.noLimit) { reported = $0 }

        XCTAssertEqual(outcome, .exited(3))
        XCTAssertEqual(String(data: stderr, encoding: .utf8), "boom\n")
        XCTAssertEqual(reported, [], "output that reached end of file was reported as cut")
    }

    /// Without `drainOnSuccess`, a clean exit ends the output at once rather
    /// than a drain grace later, even while a child holds it open. Drain
    /// grace `HeldFake.noLimit`.
    func testRunEndsOutputAtOnceAfterACleanExitWithoutDrainOnSuccess() async throws {
        let holder = try makeHolder()

        let (outcome, _) = try await run(
            "\(holder.inBackground)\nexit 0", drainGrace: HeldFake.noLimit, drainOnSuccess: false,
        ) { _ in }

        XCTAssertEqual(outcome, .exited(0))
        holder.assertNotRunOut("the clean exit waited for the output")
    }

    /// A stream the reader returned without draining is ended when the run
    /// returns, not left open behind it, and reported as cut. The child
    /// holds it open until the test is over, so end of file cannot come
    /// first; drain grace `HeldFake.noLimit`, so the drain cannot either.
    func testRunEndsAndReportsAStreamTheReaderLeftOpen() async throws {
        let holder = try makeHolder()
        var reported: [Bool] = []

        _ = try await run("\(holder.inBackground)\nexit 3", drainGrace: HeldFake.noLimit, readsOutput: false) { reported = $0 }

        XCTAssertEqual(reported, [true])
    }

    // MARK: - collectTail

    /// Only the end of the output is kept, cut where a character starts.
    func testCollectTailKeepsTheLastBytesOnACharacterBoundary() async {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        continuation.yield(Data(String(repeating: "a", count: 10).utf8))
        continuation.yield(Data("äb".utf8))
        continuation.finish()

        let tail = await ProcessOutput.collectTail(of: chunks, limit: 2)

        XCTAssertEqual(String(data: tail, encoding: .utf8), "b")
    }

    /// Trimming waits for twice the limit, but what comes back is never
    /// more than the limit.
    func testCollectTailTrimsWhatIsLeftAtTheEnd() async {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        continuation.yield(Data("abc".utf8))
        continuation.finish()

        let tail = await ProcessOutput.collectTail(of: chunks, limit: 2)

        XCTAssertEqual(String(data: tail, encoding: .utf8), "bc")
    }

    // MARK: - Helpers

    /// A child that holds the stderr it inherits until the test is over.
    private func makeHolder() throws -> HeldFake {
        try makeHeldFake(in: makeTempDirectory(prefix: "process-output"), name: "holder")
    }

    /// Runs `command` in a shell with its stderr read through `run`, or not
    /// read at all when `readsOutput` is false.
    private func run(
        _ command: String, drainGrace: TimeInterval, drainOnSuccess: Bool = true, readsOutput: Bool = true,
        onCut: ([Bool]) -> Void,
    ) async throws -> (BoundedProcess.Outcome, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        let stderr = ProcessOutput.chunks(of: pipe)
        let result = try await ProcessOutput.run(
            BoundedProcess(process, terminationGrace: Self.grace),
            timeout: HeldFake.noLimit,
            ending: [stderr.end],
            drainGrace: drainGrace,
            drainOnSuccess: drainOnSuccess,
            onCut: onCut,
        ) { readsOutput ? await ProcessOutput.collectTail(of: stderr.chunks) : Data() }
        return (result.outcome, result.output)
    }
}
