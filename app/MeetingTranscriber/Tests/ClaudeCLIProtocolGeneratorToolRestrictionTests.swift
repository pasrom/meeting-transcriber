#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The transcript is untrusted text, so the CLI session that reads it
    /// must have no tools and no MCP servers, and a CLI that cannot be
    /// restricted must never get the transcript unrestricted.
    final class ClaudeCLIProtocolGeneratorToolRestrictionTests: XCTestCase {
        // MARK: - Arguments

        /// The empty tool list is an argument of its own, directly after
        /// `--tools`, and the option after it ends the variadic list. The
        /// prompt marker `-` comes before, so `--tools` cannot swallow it.
        func testArgumentsDisableEveryToolAndEveryMCPServer() {
            for (claudeBin, resolvedBin) in [("claude", "/opt/homebrew/bin/claude"), ("claude-work", "/usr/bin/env")] {
                for noSessionPersistence in [false, true] {
                    let args = ClaudeCLIProtocolGenerator.buildSubprocessArgs(
                        claudeBin: claudeBin, resolvedBin: resolvedBin, noSessionPersistence: noSessionPersistence,
                    )
                    guard let tools = args.firstIndex(of: "--tools"), let prompt = args.firstIndex(of: "-") else {
                        XCTFail("arguments were: \(args)")
                        continue
                    }
                    XCTAssertEqual(args.firstIndex(of: "--tools"), args.lastIndex(of: "--tools"))
                    XCTAssertEqual(args[safe: tools + 1], "", "arguments were: \(args)")
                    let next = args[safe: tools + 2]
                    XCTAssertTrue(next == nil || next?.hasPrefix("--") == true, "arguments were: \(args)")
                    XCTAssertTrue(args.contains("--strict-mcp-config"), "arguments were: \(args)")
                    XCTAssertLessThan(prompt, tools, "arguments were: \(args)")
                }
            }
        }

        /// The binary name stays the first argument under the
        /// `/usr/bin/env` fallback, ahead of the restriction.
        func testEnvFallbackKeepsTheBinaryFirst() {
            let args = ClaudeCLIProtocolGenerator.buildSubprocessArgs(
                claudeBin: "claude-work", resolvedBin: "/usr/bin/env", noSessionPersistence: true,
            )
            XCTAssertEqual(args.first, "claude-work", "arguments were: \(args)")
        }

        // MARK: - generate (subprocess)

        /// The real run gets the empty value as an argument of its own, which
        /// a `$*` echo would hide: the fake brackets every argument.
        func testGeneratePassesTheEmptyToolListAsItsOwnArgument() async throws {
            let cli = try makeCLI()

            let result = try await generate(claudeBin: cli)

            XCTAssertTrue(result.contains("[--tools][][--strict-mcp-config]"), "arguments were: \(result)")
        }

        /// A CLI older than `--tools` refuses it. There is no second run
        /// without it, and the error says what to do.
        func testACLIThatRejectsToolsFailsWithoutARunUnrestricted() async throws {
            let cli = try makeCLI(rejects: "--tools")

            await assertFailsAskingForAnUpdate(claudeBin: cli, naming: "--tools")
            XCTAssertEqual(try runs(), 1)
        }

        func testACLIThatRejectsStrictMCPConfigFailsWithoutARunUnrestricted() async throws {
            let cli = try makeCLI(rejects: "--strict-mcp-config")

            await assertFailsAskingForAnUpdate(claudeBin: cli, naming: "--strict-mcp-config")
            XCTAssertEqual(try runs(), 1)
        }

        /// A CLI whose run refuses the session flag, and whose `--help` no
        /// longer lists it when asked again, gets a second run without the
        /// session flag. That run still carries the restriction, so a CLI
        /// that knows neither fails on it instead of running unrestricted.
        func testTheSessionFlagRetryKeepsTheRestriction() async throws {
            let cli = try makeCLI(rejects: Self.sessionFlag, "--tools", helpListsSessionFlagOnlyOnce: true)

            await assertFailsAskingForAnUpdate(claudeBin: cli, naming: "--tools")
            XCTAssertEqual(try runs(), 2)
        }

        /// Read as an option parser reports an option it does not know, for
        /// a run that had it. `--tools` inside another option's name, or an
        /// unrelated failure, is not a refusal.
        func testRestrictionRejectionNeedsTheOptionAndAnOptionParserWording() {
            let rejected = { (stderr: String) in
                ClaudeCLIProtocolGenerator.rejectedToolRestriction(
                    stderr: stderr, message: "", arguments: ClaudeCLIProtocolGenerator.noToolsArguments,
                )
            }
            XCTAssertTrue(rejected("error: unknown option '--tools'"))
            XCTAssertTrue(rejected("error: unknown option '--strict-mcp-config'"))
            XCTAssertFalse(rejected("error: unknown option '--disallowedTools'"))
            XCTAssertFalse(rejected("error: rate limited\nargv: --tools --strict-mcp-config"))
            XCTAssertFalse(ClaudeCLIProtocolGenerator.rejectedToolRestriction(
                stderr: "error: unknown option '--tools'", message: "", arguments: ["-p"],
            ))
            XCTAssertTrue(ClaudeCLIProtocolGenerator.rejectedToolRestriction(
                stderr: "", message: "error: unknown option '--tools'",
                arguments: ClaudeCLIProtocolGenerator.noToolsArguments,
            ))
        }

        /// A run refused the session flag, not the restriction, is still
        /// reported as that: it gets its retry, which keeps the restriction,
        /// instead of the message asking for a newer CLI.
        func testASessionFlagRejectionIsNotTakenForARestrictionRejection() {
            let arguments = ClaudeCLIProtocolGenerator.buildSubprocessArgs(
                claudeBin: "claude", resolvedBin: "/opt/homebrew/bin/claude", noSessionPersistence: true,
            )
            let error = ClaudeCLIProtocolGenerator.handleFailure(
                exitCode: 1, stderrData: Data("error: unknown option '\(Self.sessionFlag)'".utf8),
                text: "", resultEvent: nil, arguments: arguments,
            )
            XCTAssertTrue(error is ClaudeCLIProtocolGenerator.NoSessionPersistenceRejected, "error was: \(error)")
        }

        // MARK: - Helpers

        private static let sessionFlag = ClaudeCLIProtocolGenerator.noSessionPersistenceFlag

        /// Each test runs on its own instance, so on its own folder, and its
        /// CLI is a path no other test has cached a `--help` answer for.
        private let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-tools-\(UUID().uuidString)", isDirectory: true)

        override func setUpWithError() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }

        override func tearDown() {
            try? FileManager.default.removeItem(at: folder)
        }

        private var logPath: String {
            folder.appendingPathComponent("runs.log").path
        }

        /// On a clock that never moves, so the `--help` probe cannot run out
        /// on a slow runner and change which flags the run gets.
        private func generate(claudeBin: String) async throws -> String {
            try await ClaudeCLIProtocolGenerator(claudeBin: claudeBin, language: "German", clock: ManualClock())
                .generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
        }

        private func assertFailsAskingForAnUpdate(
            claudeBin: String, naming option: String, file: StaticString = #filePath, line: UInt = #line,
        ) async {
            do {
                let result = try await generate(claudeBin: claudeBin)
                XCTFail("the run should have failed, it returned: \(result)", file: file, line: line)
            } catch let ProtocolError.cliFailed(code, message) {
                XCTAssertEqual(code, 1, file: file, line: line)
                XCTAssertTrue(message.contains("Update the Claude CLI"), message, file: file, line: line)
                XCTAssertTrue(message.contains("unknown option '\(option)'"), message, file: file, line: line)
            } catch {
                XCTFail("unexpected error \(error)", file: file, line: line)
            }
        }

        /// How many protocol runs the fake CLI saw.
        private func runs() throws -> Int {
            try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n").count
        }

        /// A fake `claude` whose `--help` lists the session flag, or only on
        /// the first time it is asked. A run logs itself, drains stdin,
        /// refuses the first of `rejects` it was given, in the order listed,
        /// as an option parser does, and otherwise replies with every
        /// argument in brackets.
        private func makeCLI(rejects: String..., helpListsSessionFlagOnlyOnce: Bool = false) throws -> String {
            let helpLog = folder.appendingPathComponent("help.log").path
            let listed = "printf '%s\\n' '  \(Self.sessionFlag)  Disable session persistence'"
            let help = helpListsSessionFlagOnlyOnce
                ? "if [ -e '\(helpLog)' ]; then printf '%s\\n' '  -p, --print  Print'; else \(listed); fi"
                : listed
            let checks = rejects.map { option in
                """
                for arg in "$@"; do
                    if [ "$arg" = '\(option)' ]; then printf '%s\\n' "error: unknown option '\(option)'" >&2; exit 1; fi
                done
                """
            }.joined(separator: "\n")
            return try makeExecutableScript(in: folder, name: "claude", body: """
            if [ "$1" = "--help" ]; then
                \(help)
                echo help >> '\(helpLog)'
                exit 0
            fi
            echo run >> '\(logPath)'
            cat > /dev/null
            \(checks)
            out=''
            for arg in "$@"; do out="$out[$arg]"; done
            printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}\\n' "$out"
            """)
        }
    }

    private extension Array {
        subscript(safe index: Int) -> Element? {
            indices.contains(index) ? self[index] : nil
        }
    }
#endif
