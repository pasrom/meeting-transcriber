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
    }
#endif
