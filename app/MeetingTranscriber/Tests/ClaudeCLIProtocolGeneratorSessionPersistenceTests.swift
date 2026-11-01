#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The meeting must not end up in the Claude CLI's session store: a
    /// session holds the whole prompt, which is the transcript.
    final class ClaudeCLIProtocolGeneratorSessionPersistenceTests: XCTestCase {
        // MARK: - Arguments

        func testBuildSubprocessArgsAddsTheFlagWhenTheCLISupportsIt() {
            let args = ClaudeCLIProtocolGenerator.buildSubprocessArgs(
                claudeBin: "claude", resolvedBin: "/opt/homebrew/bin/claude", noSessionPersistence: true,
            )
            XCTAssertEqual(
                args,
                ["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet", "--no-session-persistence"],
            )
        }

        func testHelpListsNoSessionPersistenceReadsTheOptionList() {
            XCTAssertTrue(ClaudeCLIProtocolGenerator.helpListsNoSessionPersistence(
                "  --no-session-persistence              Disable session persistence - sessions",
            ))
            XCTAssertFalse(ClaudeCLIProtocolGenerator.helpListsNoSessionPersistence(
                "  -p, --print                           Print response and exit",
            ))
        }

        // MARK: - generate (subprocess)

        /// A CLI whose `--help` lists the flag gets it on the real run. The
        /// fake binary answers `--help` with one option line and otherwise
        /// replies with the arguments it was started with.
        func testGeneratePassesTheFlagToACLIThatListsIt() async throws {
            let script = try makeFakeClaudeScript(helpLine: "  --no-session-persistence  Disable session persistence")

            let generator = Self.makeGenerator(script: script)
            let result = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)

            XCTAssertTrue(result.contains("--no-session-persistence"), "arguments were: \(result)")
        }

        /// A CLI older than the flag would reject it as an unknown option and
        /// fail every protocol, so it must not get it.
        func testGenerateLeavesTheFlagOffForACLIThatDoesNotListIt() async throws {
            let script = try makeFakeClaudeScript(helpLine: "  -p, --print  Print response and exit")

            let generator = Self.makeGenerator(script: script)
            let result = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)

            XCTAssertFalse(result.contains("--no-session-persistence"), "arguments were: \(result)")
            XCTAssertTrue(result.contains("--output-format stream-json"), "arguments were: \(result)")
        }

        /// A wrapper that ignores SIGTERM and does not exit must not hold up
        /// the protocol: the probe kills it after its timeout and the
        /// termination grace, and the run goes ahead without the flag. The
        /// limit must pass after the trap and the help line.
        func testHelpProbeGivesUpOnACLIThatDoesNotExit() async throws {
            let folder = try makeTempDirectory(prefix: "help-probe")
            let cli = try makeHeldFake(in: folder, name: "cli")
            let path = try makeExecutableScript(in: folder, name: "claude", body: """
            trap '' TERM
            echo '--no-session-persistence'
            exec '\(cli.path)'
            """)

            let help = try await passLimit(of: cli, "the probe waited for a CLI that never exits") { clock, timeout in
                await ClaudeCLIProtocolGenerator(
                    claudeBin: path, language: "German", terminationGrace: 0.15, clock: clock, helpProbeTimeout: timeout,
                ).readHelp(resolvedBin: path, environment: ProcessInfo.processInfo.environment)
            }.get()

            XCTAssertNil(help, "a probe that ran out of time counts as no help text")
        }

        /// The generator's own probe is stopped at `helpProbeTimeout` on the
        /// generator's clock, and the run goes ahead without the flag: the
        /// help line printed before the hang must not count. The run's limit
        /// differs from the probe's, so `passLimit` sees which one slept.
        func testGenerateGivesUpOnAHelpProbeThatDoesNotExit() async throws {
            let cli = try makeHeldFake(in: makeTempDirectory(prefix: "help-probe"), name: "cli")
            let script = try makeFakeClaudeScript(help: """
            trap '' TERM
            echo '\(ClaudeCLIProtocolGenerator.noSessionPersistenceFlag)'
            exec '\(cli.path)'
            """)

            let result = try await passLimit(of: cli, "the probe waited for a --help that never exits") { clock, timeout in
                try await ClaudeCLIProtocolGenerator(
                    claudeBin: script, language: "German", timeout: 2 * timeout,
                    terminationGrace: 0.15, clock: clock, helpProbeTimeout: timeout,
                ).generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
            }.get()

            XCTAssertFalse(result.contains(ClaudeCLIProtocolGenerator.noSessionPersistenceFlag), "arguments were: \(result)")
            XCTAssertTrue(result.contains("--output-format stream-json"), "arguments were: \(result)")
        }

        /// The probe is stopped with the generator's own termination grace,
        /// not the 1 s default: a `--help` that ignores SIGTERM is still alive
        /// 2 s after the stop and is killed once the 6 s grace is over. The
        /// grace is wall time, as `BoundedProcess` measures it, so the "still
        /// alive" check is a settle. Its margin is 4 s each way of the 2 s
        /// check: the default grace would have to be late by a second to slip
        /// through, and a correct run would have to wake 4 s late to fail.
        func testTheHelpProbeIsKilledAfterTheGeneratorsGrace() async throws {
            let folder = try makeTempDirectory(prefix: "help-probe")
            let cli = try makeHeldFake(in: folder, name: "cli")
            let path = try makeExecutableScript(in: folder, name: "claude", body: "trap '' TERM\nexec '\(cli.path)'")
            let clock = ManualClock()
            let probe = Task {
                await ClaudeCLIProtocolGenerator(
                    claudeBin: path, language: "German", terminationGrace: 6, clock: clock,
                    helpProbeTimeout: HeldFake.testLimit,
                ).readHelp(resolvedBin: path, environment: ProcessInfo.processInfo.environment)
            }
            defer { probe.cancel() }
            try await waitForStart(of: cli)
            let deadlines = await clock.sleepingDeadlines()
            XCTAssertEqual(deadlines, [.seconds(HeldFake.testLimit)], "the probe's limit was not measured on the clock")
            guard deadlines == [.seconds(HeldFake.testLimit)] else { return }

            await clock.advance(by: .seconds(HeldFake.testLimit))
            let stoppedAt = Date()
            try await Task.sleep(for: .seconds(2))
            let pid = try XCTUnwrap(readPID(cli.pidFile))
            XCTAssertEqual(kill(pid, 0), 0, "the probe was killed before the generator's grace was over")
            _ = await probe.value

            cli.assertStopped(since: stoppedAt, "the probe was not killed once the grace was over")
        }

        func testHelpProbeReadsTheHelpOfACLIThatExits() async throws {
            let path = try makeExecutableScript(
                in: makeTempDirectory(prefix: "help-probe"), name: "claude", body: "echo \"called with $1\"",
            )

            let help = await ClaudeCLIProtocolGenerator(claudeBin: path, language: "German", clock: ManualClock())
                .readHelp(resolvedBin: path, environment: ProcessInfo.processInfo.environment)

            XCTAssertEqual(help, "called with --help\n")
        }

        // MARK: - Auto memory

        /// Set even over a value inherited from the app's environment: a
        /// protocol run never wants auto memory, whatever the shell had.
        func testBuildEnvironmentDisablesAutoMemory() {
            let env = ClaudeCLIProtocolGenerator.buildEnvironment(
                baseEnvironment: [ClaudeCLIProtocolGenerator.disableAutoMemoryVariable: "0"], searchPaths: [],
            )
            XCTAssertEqual(env[ClaudeCLIProtocolGenerator.disableAutoMemoryVariable], "1")
        }

        /// The variable reaches the started CLI, not just `buildEnvironment`'s
        /// output: the fake binary replies with the value it sees.
        func testGeneratePassesTheAutoMemoryVariableToTheCLI() async throws {
            let script = try makeFakeClaudeScript(
                helpLine: "  -p, --print  Print response and exit",
                reply: "$\(ClaudeCLIProtocolGenerator.disableAutoMemoryVariable)",
            )

            let generator = Self.makeGenerator(script: script)
            let result = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)

            XCTAssertEqual(result, "1")
        }

        // MARK: - Project folder

        /// The name Claude Code gives the folder, as measured:
        /// `/private/var/folders/<xx>/<hash>/T/MeetingTranscriber-claude-cli-<UUID>`
        /// became `-private-var-folders-<xx>-<hash>-T-MeetingTranscriber-claude-cli-<UUID>`.
        func testProjectFolderNameReplacesEverythingButLettersAndDigits() {
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.projectFolderName(
                    forPath: "/private/var/folders/ab/cd12ef_3456/T/MeetingTranscriber-claude-cli-8CA0D6D7-6A23",
                ),
                "-private-var-folders-ab-cd12ef-3456-T-MeetingTranscriber-claude-cli-8CA0D6D7-6A23",
            )
            XCTAssertEqual(ClaudeCLIProtocolGenerator.projectFolderName(forPath: "/a.b/ü c"), "-a-b---c")
        }

        func testCLIProjectFolderUsesTheConfigDirectoryAndThePhysicalPath() throws {
            let workingDirectory = try ClaudeCLIProtocolGenerator.makeWorkingDirectory()
            defer { try? FileManager.default.removeItem(at: workingDirectory) }
            let physical = try XCTUnwrap(physicalPath(workingDirectory.path))

            let folder = try XCTUnwrap(ClaudeCLIProtocolGenerator.cliProjectFolder(
                workingDirectory: workingDirectory, environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-config"],
            ))

            XCTAssertEqual(
                folder.path,
                "/tmp/claude-config/projects/" + ClaudeCLIProtocolGenerator.projectFolderName(forPath: physical),
            )
        }

        /// The CLI inherits the environment, so a `HOME` set there is where it
        /// keeps `.claude`, not the account's home directory.
        func testCLIProjectFolderFollowsTheChildsHome() throws {
            let workingDirectory = try ClaudeCLIProtocolGenerator.makeWorkingDirectory()
            defer { try? FileManager.default.removeItem(at: workingDirectory) }

            let folder = try XCTUnwrap(ClaudeCLIProtocolGenerator.cliProjectFolder(
                workingDirectory: workingDirectory, environment: ["HOME": "/tmp/other-home"],
            ))

            XCTAssertEqual(folder.deletingLastPathComponent().path, "/tmp/other-home/.claude/projects")
        }

        func testCLIProjectFolderDefaultsToDotClaudeInTheHomeDirectory() throws {
            let workingDirectory = try ClaudeCLIProtocolGenerator.makeWorkingDirectory()
            defer { try? FileManager.default.removeItem(at: workingDirectory) }

            let folder = try XCTUnwrap(ClaudeCLIProtocolGenerator.cliProjectFolder(
                workingDirectory: workingDirectory, environment: [:],
            ))

            XCTAssertEqual(
                folder.deletingLastPathComponent().path,
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects").path,
            )
        }

        func testRemoveIfOnlyEmptyFoldersRemovesWhatTheFlagLeavesBehind() throws {
            let folder = try Self.makeScratchFolder()
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("memory"), withIntermediateDirectories: false,
            )

            ClaudeCLIProtocolGenerator.removeIfOnlyEmptyFolders(folder)

            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }

        func testRemoveIfOnlyEmptyFoldersRemovesNestedEmptyFolders() throws {
            let folder = try Self.makeScratchFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("memory/a/b"), withIntermediateDirectories: true,
            )
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("other"), withIntermediateDirectories: false,
            )

            ClaudeCLIProtocolGenerator.removeIfOnlyEmptyFolders(folder)

            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }

        /// A session file (what a CLI without the flag writes) is the CLI's,
        /// not this app's, to delete.
        func testRemoveIfOnlyEmptyFoldersKeepsAFolderHoldingAFile() throws {
            let folder = try Self.makeScratchFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let memory = folder.appendingPathComponent("memory")
            try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: memory.appendingPathComponent(".session.jsonl"))

            ClaudeCLIProtocolGenerator.removeIfOnlyEmptyFolders(folder)

            XCTAssertTrue(FileManager.default.fileExists(atPath: memory.appendingPathComponent(".session.jsonl").path))
        }

        func testRemoveIfOnlyEmptyFoldersKeepsAFolderHoldingASymlink() throws {
            let folder = try Self.makeScratchFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let link = folder.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: FileManager.default.temporaryDirectory)

            ClaudeCLIProtocolGenerator.removeIfOnlyEmptyFolders(folder)

            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        }

        func testRemoveIfOnlyEmptyFoldersLeavesAFileAtThatPathAlone() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-project-\(UUID().uuidString)")
            try Data("x".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            ClaudeCLIProtocolGenerator.removeIfOnlyEmptyFolders(file)

            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }

        // MARK: - Helpers

        /// A fake `claude`: `--help` prints `helpLine`, any other call drains
        /// stdin and replies with `reply`, its own arguments by default, as
        /// one stream-json text.
        private func makeFakeClaudeScript(helpLine: String, reply: String = "$*") throws -> String {
            try makeFakeClaudeScript(help: "printf '%s\\n' '\(helpLine)'\nexit 0", reply: reply)
        }

        /// Like `makeFakeClaudeScript(helpLine:reply:)`, with `help` as the
        /// shell lines that answer `--help`.
        private func makeFakeClaudeScript(help: String, reply: String = "$*") throws -> String {
            try makeExecutableScript(in: makeTempDirectory(prefix: "fake-claude"), name: "claude", body: """
            if [ "$1" = "--help" ]; then
            \(help)
            fi
            cat > /dev/null
            printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}\\n' "\(reply)"
            """)
        }

        /// A generator for `script` on a clock that never moves, so its
        /// `--help` probe has no limit that a slow runner could reach: the
        /// probe running out would drop the flag and fail a correct run.
        private static func makeGenerator(script: String) -> ClaudeCLIProtocolGenerator {
            ClaudeCLIProtocolGenerator(claudeBin: script, language: "German", clock: ManualClock())
        }

        private static func makeScratchFolder() throws -> URL {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-project-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        }
    }
#endif
