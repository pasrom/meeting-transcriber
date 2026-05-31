#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    final class ClaudeCLIProtocolGeneratorTests: XCTestCase {
        // MARK: - parseStreamJSONLine

        func testParseStreamJSONLineExtractsContentBlockDeltaText() {
            let line = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#
            XCTAssertEqual(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line), "Hello")
        }

        func testParseStreamJSONLineExtractsAssistantText() {
            let line = #"""
            {"type":"assistant","message":{"content":[{"type":"text","text":"Final"}]}}
            """#
            XCTAssertEqual(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line), "Final")
        }

        func testParseStreamJSONLineAssistantSkipsNonTextBlocks() {
            // First block is non-text (e.g. tool_use); the loop must continue and
            // pick up the next text block.
            let line = #"""
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"x"},{"type":"text","text":"After"}]}}
            """#
            XCTAssertEqual(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line), "After")
        }

        func testParseStreamJSONLineAssistantWithoutTextBlockReturnsNil() {
            let line = #"""
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"x"}]}}
            """#
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line))
        }

        func testParseStreamJSONLineContentBlockDeltaWrongDeltaTypeReturnsNil() {
            // Anthropic stream-json carries `input_json_delta` for tool inputs;
            // those must not be confused with text content.
            let line = #"{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}"#
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line))
        }

        func testParseStreamJSONLineContentBlockDeltaMissingDeltaReturnsNil() {
            let line = #"{"type":"content_block_delta"}"#
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line))
        }

        func testParseStreamJSONLineUnknownTypeReturnsNil() {
            let line = #"{"type":"message_stop"}"#
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line))
        }

        func testParseStreamJSONLineInvalidJSONReturnsNil() {
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine("not json"))
        }

        func testParseStreamJSONLineNonObjectJSONReturnsNil() {
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine("[1,2,3]"))
        }

        func testParseStreamJSONLineAssistantMissingContentReturnsNil() {
            let line = #"{"type":"assistant","message":{}}"#
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseStreamJSONLine(line))
        }

        // MARK: - resolveClaudePath

        func testResolveClaudePathAbsolutePathReturnsAsIs() {
            // Absolute paths are trusted verbatim — even if the file doesn't
            // exist, that's the caller's problem; the resolver doesn't probe.
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.resolveClaudePath("/totally/fake/claude"),
                "/totally/fake/claude",
            )
        }

        func testResolveClaudePathFallsBackToEnvForUnknownBareName() {
            // A bare name not present in any search path falls through to the
            // /usr/bin/env shim so the production code can still attempt the
            // launch (which will fail loudly with a known error path).
            let unique = "claude-does-not-exist-\(UUID().uuidString)"
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.resolveClaudePath(unique),
                "/usr/bin/env",
            )
        }

        // MARK: - availableClaudeBinaries

        func testAvailableClaudeBinariesAlwaysIncludesClaudeFallback() {
            // "claude" is unconditionally inserted so the picker UI always has
            // at least one option even on hosts where no claude* binary is
            // installed in any of the standard search paths.
            let names = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            XCTAssertTrue(names.contains("claude"))
        }

        func testAvailableClaudeBinariesAreSortedAndDeduped() {
            let names = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            XCTAssertEqual(names, names.sorted(), "Result must be sorted")
            XCTAssertEqual(Set(names).count, names.count, "Result must be deduped")
        }

        // MARK: - searchPaths

        func testSearchPathsContainExpectedDirectories() {
            // Lock in the search-path list; changing it (e.g. adding a new
            // location) is intentional and should be reviewed alongside the
            // test update.
            let paths = ClaudeCLIProtocolGenerator.searchPaths
            XCTAssertEqual(paths.count, 4)
            XCTAssertTrue(paths.contains("/usr/local/bin"))
            XCTAssertTrue(paths.contains("/opt/homebrew/bin"))
            XCTAssertTrue(paths.contains("\(NSHomeDirectory())/.local/bin"))
            XCTAssertTrue(paths.contains("\(NSHomeDirectory())/.npm-global/bin"))
        }

        // MARK: - buildSubprocessArgs

        func testBuildSubprocessArgsForAbsolutePathDoesNotPrependBinary() {
            let args = ClaudeCLIProtocolGenerator.buildSubprocessArgs(
                claudeBin: "claude",
                resolvedBin: "/opt/homebrew/bin/claude",
            )
            XCTAssertEqual(
                args,
                ["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet"],
            )
        }

        func testBuildSubprocessArgsForEnvFallbackPrependsBinaryName() {
            // /usr/bin/env fallback: the bare name is prepended so env can
            // resolve it via PATH (set in buildEnvironment).
            let args = ClaudeCLIProtocolGenerator.buildSubprocessArgs(
                claudeBin: "claude-work",
                resolvedBin: "/usr/bin/env",
            )
            XCTAssertEqual(
                args,
                ["claude-work", "-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet"],
            )
        }

        // MARK: - buildEnvironment

        func testBuildEnvironmentRemovesClaudeCodeMarker() {
            let env = ClaudeCLIProtocolGenerator.buildEnvironment(
                baseEnvironment: ["CLAUDECODE": "1", "PATH": "/usr/bin"],
                searchPaths: [],
            )
            XCTAssertNil(env["CLAUDECODE"], "CLAUDECODE must be stripped so the nested CLI doesn't see itself as embedded")
        }

        func testBuildEnvironmentPrependsSearchPathsToPATH() {
            let env = ClaudeCLIProtocolGenerator.buildEnvironment(
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                searchPaths: ["/opt/homebrew/bin", "/Users/x/.local/bin"],
            )
            XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/Users/x/.local/bin:/usr/bin:/bin")
        }

        func testBuildEnvironmentFallsBackToSystemPathWhenNoPATHInBase() {
            let env = ClaudeCLIProtocolGenerator.buildEnvironment(
                baseEnvironment: [:],
                searchPaths: ["/opt/homebrew/bin"],
            )
            XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
        }

        func testBuildEnvironmentPreservesOtherKeys() {
            let env = ClaudeCLIProtocolGenerator.buildEnvironment(
                baseEnvironment: ["HOME": "/Users/x", "USER": "x", "PATH": "/usr/bin"],
                searchPaths: [],
            )
            XCTAssertEqual(env["HOME"], "/Users/x")
            XCTAssertEqual(env["USER"], "x")
        }

        // MARK: - drainStreamJSONLines

        func testDrainStreamJSONLinesEmptyBufferReturnsNothing() {
            var buffer = Data()
            XCTAssertEqual(ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer), [])
            XCTAssertEqual(buffer, Data())
        }

        func testDrainStreamJSONLinesPartialLineRemainsInBuffer() {
            // Single line without trailing newline — must stay in the buffer
            // for the next chunk to complete it.
            let original = Data(#"{"type":"content_block_delta""#.utf8)
            var buffer = original
            let fragments = ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer)
            XCTAssertEqual(fragments, [])
            XCTAssertEqual(buffer, original)
        }

        /// Joins parts with `\n`; `trailingNewline` controls whether the last
        /// part is terminated.
        private func makeBuffer(_ parts: [String], trailingNewline: Bool) -> Data {
            var data = Data()
            for (i, part) in parts.enumerated() {
                data.append(contentsOf: part.utf8)
                if i < parts.count - 1 || trailingNewline {
                    data.append(0x0A)
                }
            }
            return data
        }

        func testDrainStreamJSONLinesSingleCompleteLineDrains() {
            var buffer = makeBuffer(
                [#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#],
                trailingNewline: true,
            )
            let fragments = ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer)
            XCTAssertEqual(fragments, ["Hi"])
            XCTAssertEqual(buffer, Data())
        }

        func testDrainStreamJSONLinesMultipleCompleteLinesPreserveOrder() {
            var buffer = makeBuffer(
                [
                    #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"A"}}"#,
                    #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"B"}}"#,
                ],
                trailingNewline: true,
            )
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer),
                ["A", "B"],
            )
            XCTAssertEqual(buffer, Data())
        }

        func testDrainStreamJSONLinesMixOfCompleteAndPartialLeavesTailInBuffer() {
            let partial = #"{"type":"content_block_delta","del"#
            var buffer = makeBuffer(
                [#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Done"}}"#, partial],
                trailingNewline: false,
            )
            let fragments = ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer)
            XCTAssertEqual(fragments, ["Done"])
            XCTAssertEqual(buffer, Data(partial.utf8))
        }

        func testDrainStreamJSONLinesSkipsEmptyAndWhitespaceLines() {
            // Empty lines and whitespace-only lines must be skipped — Claude
            // CLI sometimes emits blank lines between JSON events.
            var buffer = makeBuffer(
                [
                    "",
                    "   ",
                    #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"OK"}}"#,
                ],
                trailingNewline: true,
            )
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer),
                ["OK"],
            )
        }

        func testDrainStreamJSONLinesSkipsUnparseableLines() {
            // Unknown event type → parseStreamJSONLine returns nil; drainer
            // must not break the loop, continue with the next line.
            var buffer = makeBuffer(
                [
                    #"{"type":"message_stop"}"#,
                    #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"After"}}"#,
                ],
                trailingNewline: true,
            )
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer),
                ["After"],
            )
        }

        func testDrainStreamJSONLinesAcrossTwoChunks() {
            // Simulate readStreamJSON: drain after the first chunk leaves
            // a partial line; the second chunk supplies the rest plus a
            // following complete line.
            var buffer = Data(#"{"type":"content_block_delta","delta":{"type":"text_delta","tex"#.utf8)
            XCTAssertEqual(ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer), [])

            buffer.append(contentsOf: #"t":"Hello"}}"#.utf8)
            buffer.append(0x0A)
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer),
                ["Hello"],
            )
            XCTAssertEqual(buffer, Data())
        }

        // MARK: - validateGeneratedText

        func testValidateGeneratedTextReturnsTrimmed() throws {
            let result = try ClaudeCLIProtocolGenerator.validateGeneratedText("  Hello world  \n")
            XCTAssertEqual(result, "Hello world")
        }

        func testValidateGeneratedTextWhitespaceOnlyThrowsEmptyProtocol() {
            // Covers both empty input and whitespace-only — the guard
            // operates on the trimmed string, so they share a branch.
            XCTAssertThrowsError(try ClaudeCLIProtocolGenerator.validateGeneratedText("   \n\t  ")) { error in
                guard case ProtocolError.emptyProtocol = error else {
                    XCTFail("Expected .emptyProtocol, got \(error)")
                    return
                }
            }
        }

        // MARK: - makeFailureError

        func testMakeFailureErrorWrapsExitCodeAndStderr() {
            let err = ClaudeCLIProtocolGenerator.makeFailureError(
                exitCode: 2,
                stderrText: "fatal: model not found",
            )
            guard case let .cliFailed(code, stderr) = err else {
                XCTFail("Expected .cliFailed, got \(err)")
                return
            }
            XCTAssertEqual(code, 2)
            XCTAssertEqual(stderr, "fatal: model not found")
        }

        func testMakeFailureErrorEmptyStderrPassesThrough() {
            let err = ClaudeCLIProtocolGenerator.makeFailureError(exitCode: 1, stderrText: "")
            guard case let .cliFailed(code, stderr) = err else {
                XCTFail("Expected .cliFailed, got \(err)")
                return
            }
            XCTAssertEqual(code, 1)
            XCTAssertEqual(stderr, "")
        }

        // MARK: - generate (subprocess integration)

        /// Drives the full `generate()` path against a fake `claude` binary that
        /// reads the piped prompt and replies with a stream-json line. Exercises
        /// the detached stdin write + close end to end — the path where the
        /// deprecated crashing `write(_:)` was replaced with the throwing
        /// `write(contentsOf:)`. The broken-pipe error the throwing call guards
        /// against can't be triggered deterministically in a unit test (it
        /// depends on the process's SIGPIPE disposition and write timing), so
        /// only the success path is asserted here.
        func testGenerateFeedsStdinAndParsesStreamJSONReply() async throws {
            let script = try Self.makeFakeClaudeScript(
                body: """
                cat > /dev/null
                printf '%s\\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Protocol body"}}'
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            let result = try await generator.generate(
                transcript: "Speaker 1: hello", title: "Sync", diarized: false,
            )
            XCTAssertEqual(result, "Protocol body")
        }

        /// Writes a temporary executable `#!/bin/sh` script wrapping `body` and
        /// returns its absolute path. Caller deletes it.
        private static func makeFakeClaudeScript(body: String) throws -> String {
            let path = NSTemporaryDirectory() + "fake-claude-\(UUID().uuidString).sh"
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path,
            )
            return path
        }
    }
#endif
