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

            try await assertTimesOut(script: script, pidFile: pidFile)

            try assertProcessGone(pidFile: pidFile)
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

            try await assertTimesOut(script: script, pidFile: pidFile)

            try assertProcessGone(pidFile: pidFile)
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

            try await assertTimesOut(script: script, pidFile: pidFile)

            try assertProcessGone(pidFile: pidFile)
        }

        /// A prompt larger than the pipe buffer that the CLI never reads,
        /// while a process it started keeps its stdin open, must not hold
        /// the run past its limit. The child leaves the CLI's process group,
        /// so stopping the CLI does not take it along, and gets stdin through
        /// fd 3 because the shell gives a background job /dev/null for stdin.
        func testGenerateTimesOutWhileThePromptCanNeverBeWritten() async throws {
            let pidFile = try XCTUnwrap(scratch).appendingPathComponent("cli.pid")
            let script = try makeFakeCLI(run: """
            exec 3<&0
            /usr/bin/perl -e 'setpgrp(0, 0); sleep 3' <&3 &
            exec 3<&-
            exec 1>&-
            echo $$ > '\(pidFile.path)'
            exec sleep 3
            """)

            try await assertTimesOut(script: script, pidFile: pidFile, transcript: Self.largeTranscript)

            try assertProcessGone(pidFile: pidFile)
        }

        /// Stopping a CLI that has not read its whole prompt breaks the pipe
        /// under the write. That must fail the write, not raise SIGPIPE and
        /// end the app (here: the test runner).
        func testGenerateSurvivesStoppingACLIThatLeftThePromptUnread() async throws {
            let pidFile = try XCTUnwrap(scratch).appendingPathComponent("cli.pid")
            let script = try makeFakeCLI(run: """
            echo $$ > '\(pidFile.path)'
            exec sleep 3
            """)

            try await assertTimesOut(script: script, pidFile: pidFile, transcript: Self.largeTranscript)

            try assertProcessGone(pidFile: pidFile)
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

            let (result, elapsed) = await Self.outcome(script: script, timeout: Self.longTimeout)

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

            let (result, _) = await Self.outcome(script: script, timeout: Self.longTimeout)

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

            let (result, elapsed) = await Self.outcome(script: script, timeout: Self.longTimeout)

            switch result {
            case let .failure(ProtocolError.cliFailed(code, message)):
                XCTAssertEqual(code, 3)
                XCTAssertEqual(message, "boom")

            default:
                XCTFail("expected cliFailed, got \(result)")
            }
            XCTAssertLessThan(elapsed, Self.bound, "the failure waited for the child's stderr")
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
            let generator = Self.makeGenerator(script: script, timeout: 30)
            let run = Task { try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false) }
            try await waitForPID(pidFile: probeFile)
            let start = Date()

            run.cancel()
            let result = await run.result

            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
            XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound)
            try assertProcessGone(pidFile: probeFile)
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
            let generator = Self.makeGenerator(script: script, timeout: 30)
            let run = Task { try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false) }
            try await waitForPID(pidFile: pidFile)
            let start = Date()

            run.cancel()
            let result = await run.result

            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
            XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound)
            try assertProcessGone(pidFile: pidFile)
        }

        // MARK: - Helpers

        /// Runs `generate` against `script` and asserts that it fails with
        /// the timeout, well before the fake CLI would have stopped by itself.
        /// The limit runs on a clock moved once the fake has written its pid
        /// to `pidFile`, the last thing each fake does before it sleeps: in
        /// real time the limit could pass first on a loaded machine, and the
        /// SIGTERM would then end a fake before it had set its trap or
        /// written the pid the assertions read.
        private func assertTimesOut(
            script: String, pidFile: URL, transcript: String = "Speaker 1: hello",
            file: StaticString = #filePath, line: UInt = #line,
        ) async throws {
            let clock = ManualClock()
            async let run = Self.outcome(script: script, timeout: Self.shortTimeout, transcript: transcript, clock: clock)
            try await waitForPID(pidFile: pidFile)
            let start = Date()
            await clock.advance(by: .seconds(Self.shortTimeout))
            let (result, _) = await run
            let elapsed = Date().timeIntervalSince(start)
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
        private static func outcome(
            script: String, timeout: TimeInterval, transcript: String = "Speaker 1: hello",
            clock: any Clock<Duration> = SuspendingClock(),
        ) async -> (result: Result<String, any Error>, elapsed: TimeInterval) {
            let generator = makeGenerator(script: script, timeout: timeout, clock: clock)
            let start = Date()
            let result: Result<String, any Error>
            do {
                result = try await .success(generator.generate(transcript: transcript, title: "Sync", diarized: false))
            } catch {
                result = .failure(error)
            }
            return (result, Date().timeIntervalSince(start))
        }

        private static func makeGenerator(
            script: String, timeout: TimeInterval, clock: any Clock<Duration> = SuspendingClock(),
        ) -> ClaudeCLIProtocolGenerator {
            ClaudeCLIProtocolGenerator(
                claudeBin: script, language: "German", timeout: timeout,
                terminationGrace: grace, outputDrainGrace: grace, clock: clock,
            )
        }

        /// Like `assertProcessGone`, for a process the CLI started: no longer
        /// this process's child once the CLI is gone, it is reaped elsewhere,
        /// a moment later.
        private func assertReaped(_ pidFile: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
            let pid = try XCTUnwrap(readPID(pidFile), "the child never started", file: file, line: line)
            let reapedBy = Date().addingTimeInterval(1)
            while kill(pid, 0) == 0, Date() < reapedBy {
                try await Task.sleep(for: .milliseconds(20))
            }
            try assertProcessGone(pidFile: pidFile, file: file, line: line)
        }

        /// A fake `claude` that runs `help` for the `--help` probe (by
        /// default answering at once) and otherwise runs `run`.
        private func makeFakeCLI(
            run: String, help: String = "echo '  -p, --print  Print response and exit'",
        ) throws -> String {
            try makeExecutableScript(in: XCTUnwrap(scratch), name: "fake-claude.sh", body: """
            if [ "$1" = "--help" ]; then
                \(help)
                exit 0
            fi
            \(run)
            """)
        }

        /// Four times a pipe buffer.
        private static let largeTranscript = String(repeating: "x", count: 256 * 1024)

        private static let replyLine =
            #"printf '%s\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Protocol body"}}'"#
    }
#endif
