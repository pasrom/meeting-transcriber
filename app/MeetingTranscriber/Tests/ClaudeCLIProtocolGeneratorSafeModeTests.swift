#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// A protocol run must not load the user's own Claude Code setup
    /// (`CLAUDE.md`, hooks, skills, plugins) into the meeting's context.
    final class ClaudeCLIProtocolGeneratorSafeModeTests: XCTestCase {
        /// Set even over a value inherited from the app's environment: a
        /// protocol run never wants the user's customizations, whatever the
        /// shell had.
        func testBuildEnvironmentTurnsSafeModeOn() {
            let env = ClaudeCLIProtocolGenerator.buildEnvironment(
                baseEnvironment: [ClaudeCLIProtocolGenerator.safeModeVariable: "0"], searchPaths: [],
            )
            XCTAssertEqual(env[ClaudeCLIProtocolGenerator.safeModeVariable], "1")
        }

        /// The variable reaches the started CLI, not just `buildEnvironment`'s
        /// output: the fake binary replies with the value it sees.
        func testGeneratePassesTheSafeModeVariableToTheCLI() async throws {
            let script = try makeExecutableScript(in: makeTempDirectory(prefix: "fake-claude"), name: "claude", body: """
            if [ "$1" = "--help" ]; then
            printf '%s\\n' '  -p, --print  Print response and exit'
            exit 0
            fi
            cat > /dev/null
            printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}\\n' "$\(ClaudeCLIProtocolGenerator.safeModeVariable)"
            """)

            // A clock that never moves, so the `--help` probe has no limit a
            // slow runner could reach.
            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German", clock: ManualClock())
            let result = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)

            XCTAssertEqual(result, "1")
        }
    }
#endif
