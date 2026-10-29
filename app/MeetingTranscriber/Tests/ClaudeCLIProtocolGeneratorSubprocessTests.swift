#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// A CLI run has to end however the CLI misbehaves: at its time limit
    /// when it goes quiet, when the job is cancelled, and soon after the CLI
    /// exits even when a process it started holds its pipes open. Fake CLIs
    /// and their children stop by themselves after three seconds, past
    /// `bound`, so a broken bound fails these tests instead of hanging them.
    final class ClaudeCLIProtocolGeneratorSubprocessTests: XCTestCase {
        /// The limit for runs expected to time out.
        private static let shortTimeout: TimeInterval = 0.2
        /// The limit for runs expected to end by themselves, far above how
        /// long they take.
        private static let longTimeout: TimeInterval = 2
        private static let grace: TimeInterval = 0.15
        private static let bound: TimeInterval = 2

        private var scratch: URL?

        override func setUpWithError() throws {
            try super.setUpWithError()
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-subprocess-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            scratch = folder
        }

        override func tearDownWithError() throws {
            // No kill of leftover fakes here: they stop by themselves, and a
            // pid read back from a file may already belong to another process.
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            try super.tearDownWithError()
        }

        // MARK: - Timeout

        /// A silent CLI that ignores SIGTERM is killed with its whole process
        /// group, so a process it started that ignores SIGTERM as well does
        /// not outlive the run either.
        func testGenerateKillsASilentCLIAndWhatItStarted() async throws {
            let folder = try XCTUnwrap(scratch)
            let pidFile = folder.appendingPathComponent("cli.pid")
            let childFile = folder.appendingPathComponent("child.pid")
            let script = try makeFakeCLI(run: """
            trap '' TERM
            sleep 3 &
            echo $! > '\(childFile.path)'
            echo $$ > '\(pidFile.path)'
            exec sleep 3
            """)

            await assertTimesOut(script: script)

            try assertGone(pidFile)
            try await assertReaped(childFile)
        }

        /// SIGTERM goes to the CLI's whole process group: a CLI that obeys
        /// it is never sent SIGKILL, and what it started goes with it.
        func testGenerateStopsWhatTheCLIStartedAlongWithIt() async throws {
            let folder = try XCTUnwrap(scratch)
            let pidFile = folder.appendingPathComponent("cli.pid")
            let childFile = folder.appendingPathComponent("child.pid")
            let script = try makeFakeCLI(run: """
            sleep 3 &
            echo $! > '\(childFile.path)'
            echo $$ > '\(pidFile.path)'
            exec sleep 3
            """)

            await assertTimesOut(script: script)

            try assertGone(pidFile)
            try await assertReaped(childFile)
        }

        /// Closing its output is not finishing: a CLI that does so and keeps
        /// running is still held to the limit while the run waits for it to
        /// exit.
        func testGenerateTimesOutOnACLIThatClosesItsOutputButKeepsRunning() async throws {
            let pidFile = try XCTUnwrap(scratch).appendingPathComponent("cli.pid")
            let script = try makeFakeCLI(run: """
            exec 1>&-
            echo $$ > '\(pidFile.path)'
            exec sleep 3
            """)

            await assertTimesOut(script: script)

            try assertGone(pidFile)
        }

        // MARK: - Runs that end by themselves

        /// A CLI that exits while a process it started still holds its output
        /// open never delivers end of file. Its protocol is whole all the
        /// same, and comes back shortly after the exit.
        func testGenerateReturnsAProtocolWhileAChildOfTheCLIKeepsItsOutputOpen() async throws {
            let script = try makeFakeCLI(run: """
            \(Self.replyLine)
            sleep 3 &
            exit 0
            """)

            let (result, elapsed) = await outcome(script: script, timeout: Self.longTimeout)

            XCTAssertEqual(try result.get(), "Protocol body")
            XCTAssertLessThan(elapsed, Self.bound, "the read waited for the child, not for the CLI")
        }

        /// More than a pipe buffer of stderr before any stdout must not
        /// stall the CLI on a pipe nobody reads yet.
        func testGenerateReadsStderrWhileTheCLIIsStillWritingIt() async throws {
            let script = try makeFakeCLI(run: """
            cat > /dev/null
            head -c 200000 /dev/zero | tr '\\0' x >&2
            \(Self.replyLine)
            """)

            let (result, _) = await outcome(script: script, timeout: Self.longTimeout)

            XCTAssertEqual(try result.get(), "Protocol body")
        }

        /// A failed CLI is reported with its stderr even when a process it
        /// started keeps stderr open.
        func testGenerateReportsAFailureWhileAChildOfTheCLIKeepsStderrOpen() async throws {
            let script = try makeFakeCLI(run: """
            sleep 3 &
            echo boom >&2
            exit 3
            """)

            let (result, elapsed) = await outcome(script: script, timeout: Self.longTimeout)

            switch result {
            case let .failure(ProtocolError.cliFailed(code, message)):
                XCTAssertEqual(code, 3)
                XCTAssertEqual(message, "boom")

            default:
                XCTFail("expected cliFailed, got \(result)")
            }
            XCTAssertLessThan(elapsed, Self.bound, "the failure waited for the child's stderr")
        }

        /// Only the end of stderr is kept, cut where a character starts.
        func testCollectTailKeepsTheLastBytesOnACharacterBoundary() async {
            let (chunks, continuation) = AsyncStream<Data>.makeStream()
            continuation.yield(Data(String(repeating: "a", count: 10).utf8))
            continuation.yield(Data("äb".utf8))
            continuation.finish()

            let tail = await ClaudeCLIProtocolGenerator.collectTail(of: chunks, limit: 2)

            XCTAssertEqual(String(data: tail, encoding: .utf8), "b")
        }

        /// Trimming waits for twice the limit, but what comes back is never
        /// more than the limit.
        func testCollectTailTrimsWhatIsLeftAtTheEnd() async {
            let (chunks, continuation) = AsyncStream<Data>.makeStream()
            continuation.yield(Data("abc".utf8))
            continuation.finish()

            let tail = await ClaudeCLIProtocolGenerator.collectTail(of: chunks, limit: 2)

            XCTAssertEqual(String(data: tail, encoding: .utf8), "bc")
        }

        // MARK: - Cancellation

        /// A job cancelled while the `--help` probe runs stops the probe and
        /// ends there: the CLI is never started for the protocol.
        func testCancellingGenerateDuringTheHelpProbeEndsTheJob() async throws {
            let folder = try XCTUnwrap(scratch)
            let probeFile = folder.appendingPathComponent("probe.pid")
            let ranFile = folder.appendingPathComponent("ran")
            let script = try makeFakeCLI(
                run: "touch '\(ranFile.path)'",
                help: "echo $$ > '\(probeFile.path)'; exec sleep 3",
            )
            let generator = makeGenerator(script: script, timeout: 30)
            let run = Task { try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false) }
            let startedBy = Date().addingTimeInterval(5)
            while Self.readPID(probeFile) == nil, Date() < startedBy {
                try await Task.sleep(for: .milliseconds(20))
            }
            let start = Date()

            run.cancel()
            let result = await run.result

            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
            XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound)
            try assertGone(probeFile)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ranFile.path), "the CLI was started after the cancel")
        }

        /// Cancelling the job stops the CLI, waits for it to exit and ends
        /// the run with a cancellation. The CLI ignores SIGTERM, so a run
        /// that returned without waiting would leave it running. The pid is
        /// written after the trap is set, so the cancel cannot come before it.
        func testCancellingGenerateStopsTheCLI() async throws {
            let pidFile = try XCTUnwrap(scratch).appendingPathComponent("cli.pid")
            let script = try makeFakeCLI(run: """
            trap '' TERM
            echo $$ > '\(pidFile.path)'
            exec sleep 3
            """)
            let generator = makeGenerator(script: script, timeout: 30)
            let run = Task { try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false) }
            let startedBy = Date().addingTimeInterval(5)
            while Self.readPID(pidFile) == nil, Date() < startedBy {
                try await Task.sleep(for: .milliseconds(20))
            }
            let start = Date()

            run.cancel()
            let result = await run.result

            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
            XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound)
            try assertGone(pidFile)
        }

        // MARK: - Helpers

        /// Runs `generate` against `script` and asserts that it fails with
        /// the timeout, well before the fake CLI would have stopped by itself.
        private func assertTimesOut(
            script: String, transcript: String = "Speaker 1: hello", file: StaticString = #filePath, line: UInt = #line,
        ) async {
            let (result, elapsed) = await outcome(script: script, timeout: Self.shortTimeout, transcript: transcript)
            switch result {
            case .failure(ProtocolError.timeout):
                break

            default:
                XCTFail("expected a timeout, got \(result)", file: file, line: line)
            }
            XCTAssertLessThan(elapsed, Self.bound, "the run outlasted its limit", file: file, line: line)
        }

        /// Runs `generate` against `script` and reports how it ended and how
        /// long it took.
        private func outcome(
            script: String, timeout: TimeInterval, transcript: String = "Speaker 1: hello",
        ) async -> (result: Result<String, any Error>, elapsed: TimeInterval) {
            let generator = makeGenerator(script: script, timeout: timeout)
            let start = Date()
            let result: Result<String, any Error>
            do {
                result = try await .success(generator.generate(transcript: transcript, title: "Sync", diarized: false))
            } catch {
                result = .failure(error)
            }
            return (result, Date().timeIntervalSince(start))
        }

        private func makeGenerator(script: String, timeout: TimeInterval) -> ClaudeCLIProtocolGenerator {
            ClaudeCLIProtocolGenerator(
                claudeBin: script, language: "German", timeout: timeout,
                terminationGrace: Self.grace, outputDrainGrace: Self.grace,
            )
        }

        /// The process whose pid `pidFile` holds has exited and been reaped.
        private func assertGone(_ pidFile: URL, file: StaticString = #filePath, line: UInt = #line) throws {
            let pid = try XCTUnwrap(Self.readPID(pidFile), "the fake CLI never started", file: file, line: line)
            let result = kill(pid, 0)
            let code = errno
            XCTAssertEqual(result, -1, "the process is still running", file: file, line: line)
            XCTAssertEqual(code, ESRCH, file: file, line: line)
        }

        /// Like `assertGone`, for a process the CLI started: no longer this
        /// process's child once the CLI is gone, it is reaped elsewhere, a
        /// moment later.
        private func assertReaped(_ pidFile: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
            let pid = try XCTUnwrap(Self.readPID(pidFile), "the child never started", file: file, line: line)
            let reapedBy = Date().addingTimeInterval(1)
            while kill(pid, 0) == 0, Date() < reapedBy {
                try await Task.sleep(for: .milliseconds(20))
            }
            try assertGone(pidFile, file: file, line: line)
        }

        /// A fake `claude` that runs `help` for the `--help` probe (by
        /// default answering at once) and otherwise runs `run`.
        private func makeFakeCLI(
            run: String, help: String = "echo '  -p, --print  Print response and exit'",
        ) throws -> String {
            let path = try XCTUnwrap(scratch).appendingPathComponent("fake-claude.sh").path
            let body = """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
                \(help)
                exit 0
            fi
            \(run)
            """
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }

        private static let replyLine =
            #"printf '%s\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Protocol body"}}'"#

        private static func readPID(_ file: URL) -> pid_t? {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
#endif
