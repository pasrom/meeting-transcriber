#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The yes `--help` gave about `--no-session-persistence` is kept across
    /// runs, so a CLI replaced by an older one that rejects the flag must be
    /// asked again, without ever starting a run without the flag for a CLI
    /// that has it.
    final class ClaudeCLIProtocolGeneratorHelpProbeCacheTests: XCTestCase {
        /// Each test runs on its own instance, so on its own folder, and the
        /// CLIs in it are paths no other test has cached an answer for.
        private let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-help-cache-\(UUID().uuidString)", isDirectory: true)

        override func setUpWithError() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }

        override func tearDown() {
            try? FileManager.default.removeItem(at: folder)
        }

        /// A yes is remembered: a second run with the same CLI does not start
        /// `--help` again.
        func testACachedYesIsReusedWithoutAskingAgain() async throws {
            let cli = try makeCLI(help: .lists)

            _ = try await generate(claudeBin: cli)
            _ = try await generate(claudeBin: cli)

            XCTAssertEqual(try calls(), ["help", "run+flag", "run+flag"])
        }

        /// An older CLI installed over the one that said yes refuses the
        /// flag; it is asked again and the protocol comes from a run without.
        func testACLIDowngradedAtTheSamePathIsRetriedWithoutTheFlag() async throws {
            let cli = try makeCLI(help: .lists)
            _ = try await generate(claudeBin: cli)

            _ = try makeCLI(help: .doesNotList, failure: .rejectsFlag(Self.rejection))
            let result = try await generate(claudeBin: cli)

            XCTAssertFalse(result.contains(Self.flag), "arguments were: \(result)")
            XCTAssertEqual(try calls(), ["help", "run+flag", "run+flag", "help", "run-flag"])
        }

        /// The refusal is read from stderr even when the CLI also wrote a
        /// result event, whose reason the reported error prefers.
        func testARejectionOnStderrBehindAResultEventIsRetried() async throws {
            let cli = try makeCLI(help: .lists)
            _ = try await generate(claudeBin: cli)

            _ = try makeCLI(help: .doesNotList, failure: .rejectsFlagBehindResultEvent(Self.rejection))
            _ = try await generate(claudeBin: cli)

            XCTAssertEqual(try calls(), ["help", "run+flag", "run+flag", "help", "run-flag"])
        }

        /// A CLI whose `--help` lists the flag keeps getting it, even when
        /// its run refuses it: there is no second run with the same
        /// arguments, and none without the flag.
        func testACLIThatListsTheFlagIsNeverRunWithoutIt() async throws {
            let cli = try makeCLI(help: .lists, failure: .rejectsFlag(Self.rejection))

            await assertFails(claudeBin: cli, with: Self.rejection)
            XCTAssertEqual(try calls(), ["help", "run+flag", "help"])
        }

        /// When asking again gets no readable answer, nothing says the CLI
        /// lacks the flag, so there is no run without it.
        func testARetryWhoseHelpCannotBeReadKeepsTheOriginalError() async throws {
            let cli = try makeCLI(help: .lists)
            _ = try await generate(claudeBin: cli)

            _ = try makeCLI(help: .unreadable, failure: .rejectsFlag(Self.rejection))
            await assertFails(claudeBin: cli, with: Self.rejection)
            XCTAssertEqual(try calls(), ["help", "run+flag", "run+flag", "help"])
        }

        /// Only a refusal of the flag earns a second run: any other failure
        /// is the protocol's failure, reported as it was.
        func testAFailureThatDoesNotNameTheFlagIsNotRetried() async throws {
            let cli = try makeCLI(help: .lists, failure: .always("error: rate limited"))

            await assertFails(claudeBin: cli, with: "error: rate limited")
            XCTAssertEqual(try calls(), ["help", "run+flag"])
        }

        /// Read as an option parser reports an option it does not know, on
        /// one line, and only for a run that had the flag. The flag merely
        /// appearing, in an echo of the arguments or a usage text after
        /// some other error, is not a refusal.
        func testRejectionNeedsTheFlagAndAnOptionParserWording() {
            let rejected = { (stderr: String, arguments: [String]) in
                ClaudeCLIProtocolGenerator.rejectedNoSessionPersistence(stderr: stderr, message: "", arguments: arguments)
            }
            let withFlag = ["-p", Self.flag]

            XCTAssertTrue(rejected(Self.rejection, withFlag))
            XCTAssertTrue(rejected("Error: Unrecognized option: \(Self.flag)", withFlag))
            XCTAssertTrue(rejected("invalid option \(Self.flag)\n(Did you mean --print?)", withFlag))
            XCTAssertFalse(rejected(Self.rejection, ["-p"]))
            XCTAssertFalse(rejected("error: authentication failed\nargv: -p \(Self.flag)", withFlag))
            XCTAssertFalse(rejected("error: unknown option '--foo'\nUsage:\n  \(Self.flag)  Disable", withFlag))
            XCTAssertTrue(ClaudeCLIProtocolGenerator.rejectedNoSessionPersistence(
                stderr: "", message: Self.rejection, arguments: withFlag,
            ))
        }

        // MARK: - Helpers

        private static let flag = ClaudeCLIProtocolGenerator.noSessionPersistenceFlag
        /// What the CLI's option parser prints for an option it does not know.
        private static let rejection = "error: unknown option '\(flag)'"

        private enum Help {
            case lists
            case doesNotList
            /// Not valid UTF-8, so the help text cannot be read.
            case unreadable
        }

        private enum Failure {
            /// Fails with this message on stderr when given the flag.
            case rejectsFlag(String)
            /// Like `rejectsFlag`, after writing a failed result event with
            /// a reason of its own to stdout.
            case rejectsFlagBehindResultEvent(String)
            /// Fails with this message on stderr on every run.
            case always(String)
        }

        private var cliPath: String {
            folder.appendingPathComponent("claude").path
        }

        private var logPath: String {
            folder.appendingPathComponent("calls.log").path
        }

        /// On a clock that never moves, so neither the run's limit nor the
        /// `--help` probe's can pass however slow the runner is: the probe
        /// running out would turn a yes into an unread answer and change the
        /// calls these tests count.
        private func generate(claudeBin: String) async throws -> String {
            try await ClaudeCLIProtocolGenerator(claudeBin: claudeBin, language: "German", clock: ManualClock())
                .generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
        }

        private func assertFails(
            claudeBin: String, with expected: String, file: StaticString = #filePath, line: UInt = #line,
        ) async {
            do {
                _ = try await generate(claudeBin: claudeBin)
                XCTFail("the run should have failed", file: file, line: line)
            } catch let ProtocolError.cliFailed(code, message) {
                XCTAssertEqual(code, 1, file: file, line: line)
                XCTAssertEqual(message, expected, file: file, line: line)
            } catch {
                XCTFail("unexpected error \(error)", file: file, line: line)
            }
        }

        /// Every start of the fake CLI in this test, in order: `help` for a
        /// `--help` probe, `run+flag` or `run-flag` for a protocol run with
        /// or without the flag.
        private func calls() throws -> [String] {
            try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n").map(String.init)
        }

        /// A fake `claude` in the test's folder, written as a new file over
        /// any earlier one, as an installer replacing a binary does. A run
        /// drains stdin, fails as `failure` says, and otherwise replies with
        /// its arguments as one stream-json text.
        private func makeCLI(help: Help, failure: Failure? = nil) throws -> String {
            let helpOutput = switch help {
            case .lists: "printf '%s\\n' '  \(Self.flag)  Disable session persistence'"
            case .doesNotList: "printf '%s\\n' '  -p, --print  Print response'"
            case .unreadable: "printf '\\377\\n'"
            }
            let body = """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
                echo help >> '\(logPath)'
                \(helpOutput)
                exit 0
            fi
            given=-flag
            for arg in "$@"; do
                if [ "$arg" = '\(Self.flag)' ]; then given=+flag; fi
            done
            echo "run$given" >> '\(logPath)'
            cat > /dev/null
            \(Self.failureLines(failure))
            printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}\\n' "$*"

            """
            try body.write(toFile: cliPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliPath)
            return cliPath
        }

        private static func failureLines(_ failure: Failure?) -> String {
            switch failure {
            case let .rejectsFlag(message):
                "if [ $given = +flag ]; then printf '%s\\n' \"\(message)\" >&2; exit 1; fi"

            case let .rejectsFlagBehindResultEvent(message):
                """
                if [ $given = +flag ]; then
                    printf '%s\\n' '{"type":"result","is_error":true,"errors":["CLI stopped"]}'
                    printf '%s\\n' "\(message)" >&2
                    exit 1
                fi
                """

            case let .always(message):
                "printf '%s\\n' \"\(message)\" >&2; exit 1"

            case nil:
                ""
            }
        }
    }
#endif
