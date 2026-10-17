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
            let script = try Self.makeFakeClaudeScript(helpLine: "  --no-session-persistence  Disable session persistence")
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            let result = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)

            XCTAssertTrue(result.contains("--no-session-persistence"), "arguments were: \(result)")
        }

        /// A CLI older than the flag would reject it as an unknown option and
        /// fail every protocol, so it must not get it.
        func testGenerateLeavesTheFlagOffForACLIThatDoesNotListIt() async throws {
            let script = try Self.makeFakeClaudeScript(helpLine: "  -p, --print  Print response and exit")
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            let result = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)

            XCTAssertFalse(result.contains("--no-session-persistence"), "arguments were: \(result)")
            XCTAssertTrue(result.contains("--output-format stream-json"), "arguments were: \(result)")
        }

        /// A wrapper that ignores SIGTERM and does not exit must not hold up
        /// the protocol: the probe gives up after its timeout and the run
        /// goes ahead without the flag.
        func testHelpProbeGivesUpOnACLIThatDoesNotExit() async throws {
            let path = NSTemporaryDirectory() + "fake-claude-\(UUID().uuidString).sh"
            try "#!/bin/sh\ntrap '' TERM\necho '--no-session-persistence'\nsleep 5\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            defer { try? FileManager.default.removeItem(atPath: path) }

            let start = Date()
            let help = await ClaudeCLIProtocolGenerator.readHelp(
                resolvedBin: path, claudeBin: path, environment: ProcessInfo.processInfo.environment, timeout: 0.5,
            )

            XCTAssertNil(help, "a probe that ran out of time counts as no help text")
            XCTAssertLessThan(Date().timeIntervalSince(start), 3, "the probe waited for a CLI that never exits")
        }

        func testHelpProbeReadsTheHelpOfACLIThatExits() async throws {
            let path = NSTemporaryDirectory() + "fake-claude-\(UUID().uuidString).sh"
            try "#!/bin/sh\necho \"called with $1\"\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            defer { try? FileManager.default.removeItem(atPath: path) }

            let help = await ClaudeCLIProtocolGenerator.readHelp(
                resolvedBin: path, claudeBin: path, environment: ProcessInfo.processInfo.environment,
            )

            XCTAssertEqual(help, "called with --help\n")
        }

        // MARK: - Project folder

        /// The name Claude Code gives the folder, as measured on this
        /// machine: `/private/var/folders/7n/43bfgc_d41d…/T/MeetingTranscriber-claude-cli-<UUID>`
        /// became `-private-var-folders-7n-43bfgc-d41d…-T-MeetingTranscriber-claude-cli-<UUID>`.
        func testProjectFolderNameReplacesEverythingButLettersAndDigits() {
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.projectFolderName(
                    forPath: "/private/var/folders/7n/43bfgc_d41d/T/MeetingTranscriber-claude-cli-8CA0D6D7-6A23",
                ),
                "-private-var-folders-7n-43bfgc-d41d-T-MeetingTranscriber-claude-cli-8CA0D6D7-6A23",
            )
            XCTAssertEqual(ClaudeCLIProtocolGenerator.projectFolderName(forPath: "/a.b/ü c"), "-a-b---c")
        }

        func testCLIProjectFolderUsesTheConfigDirectoryAndThePhysicalPath() throws {
            let workingDirectory = try ClaudeCLIProtocolGenerator.makeWorkingDirectory()
            defer { try? FileManager.default.removeItem(at: workingDirectory) }
            let physical = try XCTUnwrap(Self.physicalPath(workingDirectory.path))

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
        /// stdin and replies with its own arguments as one stream-json text.
        private static func makeFakeClaudeScript(helpLine: String) throws -> String {
            let path = NSTemporaryDirectory() + "fake-claude-\(UUID().uuidString).sh"
            let body = """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
                printf '%s\\n' '\(helpLine)'
                exit 0
            fi
            cat > /dev/null
            printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}\\n' "$*"
            """
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }

        private static func makeScratchFolder() throws -> URL {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-project-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        }

        private static func physicalPath(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
#endif
