#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// A CLI run has to end however the CLI misbehaves: at its time limit
    /// when it goes quiet, when the job is cancelled, and soon after the CLI
    /// exits even when a process it started holds its pipes open.
    ///
    /// No verdict rests on how fast the run was: a fake CLI that must be
    /// stopped, and a process it starts that the run must not wait for, are
    /// `HeldFake`s, and limits not under test are `HeldFake.noLimit`. The time
    /// checks left are coarse ceilings on a stop, `HeldFake.stopBound`.
    final class ClaudeCLIProtocolGeneratorSubprocessTests: XCTestCase {
        private static let grace: TimeInterval = 0.15

        private var scratch: URL?

        override func setUpWithError() throws {
            try super.setUpWithError()
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-subprocess-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            scratch = folder
        }

        override func tearDownWithError() throws {
            // Removing the folder releases every held fake. No kill of
            // leftovers by pid: one read back from a file may already belong
            // to another process.
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            try super.tearDownWithError()
        }

        // MARK: - Timeout

        /// A silent CLI that ignores SIGTERM is killed with its whole process
        /// group, so a process it started that ignores SIGTERM as well does
        /// not outlive the run either.
        func testGenerateKillsASilentCLIAndWhatItStarted() async throws {
            let folder = try XCTUnwrap(scratch)
            let cli = try makeHeldFake(in: folder, name: "cli")
            let child = try makeHeldFake(in: folder, name: "child")
            let script = try makeFakeCLI(run: """
            trap '' TERM
            \(child.inBackground)
            exec '\(cli.path)'
            """)

            try await assertTimesOut(script: script, cli: cli)

            try await assertReaped(child)
        }

        /// SIGTERM goes to the CLI's whole process group: a CLI that obeys
        /// it is never sent SIGKILL, and what it started goes with it.
        func testGenerateStopsWhatTheCLIStartedAlongWithIt() async throws {
            let folder = try XCTUnwrap(scratch)
            let cli = try makeHeldFake(in: folder, name: "cli")
            let child = try makeHeldFake(in: folder, name: "child")
            let script = try makeFakeCLI(run: """
            \(child.inBackground)
            exec '\(cli.path)'
            """)

            try await assertTimesOut(script: script, cli: cli)

            try await assertReaped(child)
        }

        /// Closing its output is not finishing: a CLI that does so and keeps
        /// running is still held to the limit while the run waits for it to
        /// exit.
        func testGenerateTimesOutOnACLIThatClosesItsOutputButKeepsRunning() async throws {
            let cli = try makeHeldFake(in: XCTUnwrap(scratch), name: "cli")
            let script = try makeFakeCLI(run: """
            exec 1>&-
            exec '\(cli.path)'
            """)

            try await assertTimesOut(script: script, cli: cli)
        }

        /// A prompt larger than the pipe buffer that the CLI never reads,
        /// while a process it started keeps its stdin open, must not hold
        /// the run past its limit. The child leaves the CLI's process group,
        /// so stopping the CLI does not take it along, and gets stdin through
        /// fd 3 because the shell gives a background job /dev/null for stdin.
        /// The CLI goes on only once the child has started, and so left the
        /// group: stopped before that, the child went with it, the prompt's
        /// pipe closed, and the test passed without testing anything.
        func testGenerateTimesOutWhileThePromptCanNeverBeWritten() async throws {
            let folder = try XCTUnwrap(scratch)
            let cli = try makeHeldFake(in: folder, name: "cli")
            let child = try makeHeldFake(in: folder, name: "child")
            let script = try makeFakeCLI(run: """
            exec 3<&0
            /usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' '\(child.path)' <&3 &
            exec 3<&-
            exec 1>&-
            \(child.shellWaitForStart)
            exec '\(cli.path)'
            """)

            try await assertTimesOut(script: script, cli: cli, transcript: Self.largeTranscript)

            child.assertNotRunOut("the run waited for the prompt to be written")
        }

        /// Stopping a CLI that has not read its whole prompt breaks the pipe
        /// under the write. That must fail the write, not raise SIGPIPE and
        /// end the app (here: the test runner).
        func testGenerateSurvivesStoppingACLIThatLeftThePromptUnread() async throws {
            let cli = try makeHeldFake(in: XCTUnwrap(scratch), name: "cli")
            let script = try makeFakeCLI(run: "exec '\(cli.path)'")

            try await assertTimesOut(script: script, cli: cli, transcript: Self.largeTranscript)
        }

        // MARK: - Runs that end by themselves

        /// A CLI that exits while a process it started still holds its output
        /// open never delivers end of file. Its protocol is whole all the
        /// same, and comes back a drain grace after the exit. The app's own
        /// grace, not `grace`: a short one would race the reading of the
        /// reply on a slow runner.
        func testGenerateReturnsAProtocolWhileAChildOfTheCLIKeepsItsOutputOpen() async throws {
            let child = try makeHeldFake(in: XCTUnwrap(scratch), name: "child")
            let script = try makeFakeCLI(run: """
            \(Self.replyLine)
            \(child.inBackground)
            exit 0
            """)

            let result = await Self.outcome(script: script, drainGrace: ProcessOutput.defaultDrainGrace)

            XCTAssertEqual(try result.get(), "Protocol body")
            child.assertNotRunOut("the read waited for the child, not for the CLI")
        }

        /// More than a pipe buffer of stderr before any stdout must not
        /// stall the CLI on a pipe nobody reads yet.
        func testGenerateReadsStderrWhileTheCLIIsStillWritingIt() async throws {
            let script = try makeFakeCLI(run: """
            cat > /dev/null
            head -c 200000 /dev/zero | tr '\\0' x >&2
            \(Self.replyLine)
            """)

            let result = await Self.outcome(script: script)

            XCTAssertEqual(try result.get(), "Protocol body")
        }

        /// A failed CLI is reported with its stderr even when a process it
        /// started keeps stderr open: the drain grace ends the wait, not end
        /// of file.
        func testGenerateReportsAFailureWhileAChildOfTheCLIKeepsStderrOpen() async throws {
            let child = try makeHeldFake(in: XCTUnwrap(scratch), name: "child")
            let script = try makeFakeCLI(run: """
            \(child.inBackground)
            echo boom >&2
            exit 3
            """)

            let result = await Self.outcome(script: script, drainGrace: ProcessOutput.defaultDrainGrace)

            switch result {
            case let .failure(ProtocolError.cliFailed(code, message)):
                XCTAssertEqual(code, 3)
                XCTAssertEqual(message, "boom")

            default:
                XCTFail("expected cliFailed, got \(result)")
            }
            child.assertNotRunOut("the failure waited for the child's stderr")
        }

        // MARK: - Cancellation

        /// A job cancelled while the `--help` probe runs stops the probe and
        /// ends there: the CLI is never started for the protocol. The probe's
        /// own limit is `HeldFake.noLimit`, past the point where the held probe
        /// gives up, so only the cancel can have stopped it before then: the
        /// probe's marker says whether it did, and `HeldFake.stopBound` is the
        /// coarse ceiling on how long after the cancel.
        func testCancellingGenerateDuringTheHelpProbeEndsTheJob() async throws {
            let folder = try XCTUnwrap(scratch)
            let ranFile = folder.appendingPathComponent("ran")
            let probe = try makeHeldFake(in: folder, name: "probe")
            let script = try makeFakeCLI(run: "touch '\(ranFile.path)'", help: "exec '\(probe.path)'")
            let generator = Self.makeGenerator(script: script)
            let run = Task { try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false) }
            defer { run.cancel() }
            try await waitForStart(of: probe)
            let start = Date()

            run.cancel()
            let result = await run.result

            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
            probe.assertStopped(since: start, "the probe was not stopped")
            XCTAssertFalse(FileManager.default.fileExists(atPath: ranFile.path), "the CLI was started after the cancel")
        }

        /// Cancelling the job stops the CLI, waits for it to exit and ends
        /// the run with a cancellation. The CLI ignores SIGTERM, so a run
        /// that returned without waiting would leave it running. The held
        /// CLI starts after the trap is set, so the cancel cannot
        /// come before it.
        func testCancellingGenerateStopsTheCLI() async throws {
            let cli = try makeHeldFake(in: XCTUnwrap(scratch), name: "cli")
            let script = try makeFakeCLI(run: """
            trap '' TERM
            exec '\(cli.path)'
            """)
            let generator = Self.makeGenerator(script: script)
            let run = Task { try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false) }
            defer { run.cancel() }
            try await waitForStart(of: cli)
            let start = Date()

            run.cancel()
            let result = await run.result

            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
            cli.assertStopped(since: start, "the CLI was not stopped")
        }

        // MARK: - Helpers

        /// Runs `generate` against `script` and asserts that it fails with
        /// the timeout, and that the fake CLI `cli` was stopped rather than
        /// left to give up (`passLimit`).
        private func assertTimesOut(
            script: String, cli: HeldFake, transcript: String = "Speaker 1: hello",
            file: StaticString = #filePath, line: UInt = #line,
        ) async throws {
            let result = try await passLimit(of: cli, "the CLI was not stopped", file: file, line: line) { clock, timeout in
                try await Self.makeGenerator(script: script, timeout: timeout, clock: clock)
                    .generate(transcript: transcript, title: "Sync", diarized: false)
            }
            switch result {
            case .failure(ProtocolError.timeout):
                break

            default:
                XCTFail("expected a timeout, got \(result)", file: file, line: line)
            }
        }

        /// Runs `generate` against `script` and reports how it ended.
        private static func outcome(
            script: String, drainGrace: TimeInterval = HeldFake.noLimit,
        ) async -> Result<String, any Error> {
            let generator = makeGenerator(script: script, drainGrace: drainGrace)
            do {
                return try await .success(generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false))
            } catch {
                return .failure(error)
            }
        }

        private static func makeGenerator(
            script: String, timeout: TimeInterval = HeldFake.noLimit, drainGrace: TimeInterval = HeldFake.noLimit,
            clock: any Clock<Duration> = SuspendingClock(),
        ) -> ClaudeCLIProtocolGenerator {
            ClaudeCLIProtocolGenerator(
                claudeBin: script, language: "German", timeout: timeout,
                terminationGrace: grace, outputDrainGrace: drainGrace, clock: clock,
                helpProbeTimeout: HeldFake.noLimit,
            )
        }

        /// Like `assertProcessGone`, for a process the CLI started: no longer
        /// this process's child once the CLI is gone, it is reaped elsewhere,
        /// a moment later. Waits up to `HeldFake.stopBound` for that; the child holds
        /// until the test is over, so only a stop ends it before then.
        private func assertReaped(_ child: HeldFake, file: StaticString = #filePath, line: UInt = #line) async throws {
            let pidFile = child.pidFile
            child.assertNotRunOut("the child gave up instead of being stopped", file: file, line: line)
            let pid = try XCTUnwrap(readPID(pidFile), "the child wrote no pid", file: file, line: line)
            let reapedBy = Date().addingTimeInterval(HeldFake.stopBound)
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
