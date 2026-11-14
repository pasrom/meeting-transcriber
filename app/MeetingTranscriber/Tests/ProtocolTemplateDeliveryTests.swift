#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// What the Claude CLI receives on stdin for a job with a template of the
    /// user's own, through a `#!/bin/sh` fake that records its input.
    final class ProtocolTemplateDeliveryTests: XCTestCase {
        func testClaudeCLIReceivesTheTemplateOnStdin() async throws {
            let dir = try makeTempDirectory(prefix: "protocol-template-delivery")
            let received = dir.appendingPathComponent("stdin")
            let script = try makeExecutableScript(in: dir, name: "claude", body: """
            if [ "$1" = "--help" ]; then
                exit 0
            fi
            cat > '\(received.path)'
            printf '%s\\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Notes body"}}'
            """)

            // A clock that never moves, so the `--help` probe cannot run out on a slow runner.
            let result = try await ClaudeCLIProtocolGenerator(claudeBin: script, language: "German", clock: ManualClock())
                .generate(
                    transcript: "Speaker 1: hello", title: "Sync", diarized: false, meetingStartTime: nil,
                    instructions: ProtocolInstructions(template: "Board template in {LANGUAGE}."),
                )

            XCTAssertEqual(result, "Notes body")
            XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), "Board template in German.Speaker 1: hello")
        }
    }
#endif
