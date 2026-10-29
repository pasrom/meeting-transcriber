@testable import MeetingTranscriber
import XCTest

final class ProcessOutputTests: XCTestCase {
    private static let grace: TimeInterval = 0.15
    private static let bound: TimeInterval = 2

    // MARK: - run

    /// After a failed exit, output a process's child still holds open is
    /// ended a drain grace later and reported as cut. The child stops by
    /// itself after three seconds, past `bound`, so a missing drain fails the
    /// test instead of hanging it.
    func testRunEndsOutputAChildHoldsOpenADrainGraceAfterTheExit() async throws {
        let start = Date()
        var reported: [Bool] = []

        let (outcome, stderr) = try await run("sleep 3 & echo boom >&2; exit 3", drainGrace: Self.grace) { reported = $0 }

        XCTAssertEqual(outcome, .exited(3))
        XCTAssertEqual(String(data: stderr, encoding: .utf8), "boom\n")
        XCTAssertEqual(reported, [true])
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound)
    }

    /// Output that reaches end of file is not reported as cut.
    func testRunDoesNotReportOutputThatEndedByItself() async throws {
        var reported: [Bool] = []

        let (outcome, stderr) = try await run("echo boom >&2; exit 3", drainGrace: Self.grace) { reported = $0 }

        XCTAssertEqual(outcome, .exited(3))
        XCTAssertEqual(String(data: stderr, encoding: .utf8), "boom\n")
        XCTAssertEqual(reported, [], "output that reached end of file was reported as cut")
    }

    /// Without `drainOnSuccess`, a clean exit ends the output at once rather
    /// than a drain grace later, even while a child holds it open.
    func testRunEndsOutputAtOnceAfterACleanExitWithoutDrainOnSuccess() async throws {
        let start = Date()

        let (outcome, _) = try await run("sleep 3 & exit 0", drainGrace: Self.bound, drainOnSuccess: false) { _ in }

        XCTAssertEqual(outcome, .exited(0))
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound / 2)
    }

    /// A stream the reader returned without draining is ended when the run
    /// returns, not left open behind it, and reported as cut.
    func testRunEndsAndReportsAStreamTheReaderLeftOpen() async throws {
        var reported: [Bool] = []

        _ = try await run("sleep 3 & exit 3", drainGrace: Self.bound, readsOutput: false) { reported = $0 }

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
            timeout: 30,
            ending: [stderr.end],
            drainGrace: drainGrace,
            drainOnSuccess: drainOnSuccess,
            onCut: onCut,
        ) { readsOutput ? await ProcessOutput.collectTail(of: stderr.chunks) : Data() }
        return (result.outcome, result.output)
    }
}
