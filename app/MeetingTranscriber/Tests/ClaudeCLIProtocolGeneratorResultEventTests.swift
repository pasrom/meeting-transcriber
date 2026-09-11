#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Sourcing a failed run's diagnostic message from the stream-json
    /// terminal `result` event instead of the accumulated assistant text,
    /// which can be a complete generated protocol.
    ///
    /// Split out of `ClaudeCLIProtocolGeneratorTests`, which was at the
    /// 600-line lint ceiling: `parseResultEvent`/`resultEventFailureReason`/
    /// `publicFailureMessage` plus their `drainStreamJSONLines` and
    /// `generate()` integration coverage — a follow-up to PR #692's 11 Sep
    /// 2026 review, which flagged that redacting `ClaudeCLIProtocolGenerator`
    /// and `PipelineQueue+Stages.swift`'s failure logs to `.private` also
    /// silenced harmless, content-free reasons (cliNotFound, timeout,
    /// emptyProtocol, an OpenAI provider error). See
    /// `ClaudeCLIProtocolGenerator.ResultEventInfo`'s doc comment for the
    /// verified stream-json shapes this relies on.
    final class ClaudeCLIProtocolGeneratorResultEventTests: XCTestCase {
        // MARK: - parseResultEvent

        func testParseResultEventIgnoresNonResultTypes() {
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseResultEvent(#"{"type":"assistant"}"#))
        }

        func testParseResultEventIgnoresMalformedJSON() {
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseResultEvent("not json"))
        }

        func testParseResultEventSuccessShape() {
            let line = #"{"type":"result","subtype":"success","is_error":false,"result":"Protocol body","terminal_reason":"completed"}"#
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.parseResultEvent(line),
                ClaudeCLIProtocolGenerator.ResultEventInfo(
                    isError: false, errors: [], result: "Protocol body", terminalReason: "completed",
                ),
            )
        }

        func testParseResultEventStructuralFailureShape() {
            let line = #"{"type":"result","subtype":"error_max_turns","is_error":true,"errors":["Reached maximum number of turns (50)"]}"#
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.parseResultEvent(line),
                ClaudeCLIProtocolGenerator.ResultEventInfo(
                    isError: true, errors: ["Reached maximum number of turns (50)"], result: nil, terminalReason: nil,
                ),
            )
        }

        func testParseResultEventInTurnAPIErrorShape() {
            // subtype stays "success" — the CLI reports this shape when a
            // single-turn run fails immediately with an API error (e.g. an
            // expired OAuth session). terminal_reason is what actually
            // marks it as this failure mode; subtype/is_error alone don't.
            let line = #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","#
                + #""result":"Failed to authenticate. API Error: 401 API key is invalid."}"#
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.parseResultEvent(line),
                ClaudeCLIProtocolGenerator.ResultEventInfo(
                    isError: true, errors: [], result: "Failed to authenticate. API Error: 401 API key is invalid.",
                    terminalReason: "api_error",
                ),
            )
        }

        // MARK: - resultEventFailureReason

        func testResultEventFailureReasonPrefersErrorsArray() {
            // errors is always content-free by construction, so it doesn't
            // need terminalReason confirmation the way result does.
            let event = ClaudeCLIProtocolGenerator.ResultEventInfo(
                isError: true, errors: ["a", "b"], result: "ignored", terminalReason: nil,
            )
            XCTAssertEqual(ClaudeCLIProtocolGenerator.resultEventFailureReason(event), "a; b")
        }

        func testResultEventFailureReasonUsesResultWhenTerminalReasonConfirmsAPIError() {
            let event = ClaudeCLIProtocolGenerator.ResultEventInfo(
                isError: true, errors: [], result: "bad key", terminalReason: "api_error",
            )
            XCTAssertEqual(ClaudeCLIProtocolGenerator.resultEventFailureReason(event), "bad key")
        }

        /// The safety of trusting `result` rests entirely on `terminalReason
        /// == "api_error"` — without it, `result` could just as easily be a
        /// complete generated protocol (see `ResultEventInfo`'s doc comment,
        /// per the PR #710 review). No `terminalReason` at all must fail
        /// closed to nil, not trust `result` anyway.
        func testResultEventFailureReasonFailsClosedWhenTerminalReasonMissing() {
            let event = ClaudeCLIProtocolGenerator.ResultEventInfo(
                isError: true, errors: [], result: "bad key", terminalReason: nil,
            )
            XCTAssertNil(ClaudeCLIProtocolGenerator.resultEventFailureReason(event))
        }

        /// Same guard, a recognised-but-wrong terminalReason rather than a
        /// missing one — must still fail closed rather than trust `result`.
        func testResultEventFailureReasonFailsClosedWhenTerminalReasonIsNotAPIError() {
            let event = ClaudeCLIProtocolGenerator.ResultEventInfo(
                isError: true, errors: [], result: "bad key", terminalReason: "context_limit",
            )
            XCTAssertNil(ClaudeCLIProtocolGenerator.resultEventFailureReason(event))
        }

        func testResultEventFailureReasonNilWhenNotAnError() {
            let event = ClaudeCLIProtocolGenerator.ResultEventInfo(
                isError: false, errors: [], result: "Protocol body", terminalReason: "completed",
            )
            XCTAssertNil(ClaudeCLIProtocolGenerator.resultEventFailureReason(event))
        }

        func testResultEventFailureReasonNilWhenEventMissing() {
            XCTAssertNil(ClaudeCLIProtocolGenerator.resultEventFailureReason(nil))
        }

        // MARK: - publicFailureMessage

        func testPublicFailureMessagePrefersResultEventReason() {
            let event = ClaudeCLIProtocolGenerator.ResultEventInfo(
                isError: true, errors: ["bad key"], result: nil, terminalReason: nil,
            )
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.publicFailureMessage(resultEvent: event, stderrText: "irrelevant"),
                "bad key",
            )
        }

        func testPublicFailureMessageFallsBackToStderrWhenNoResultEvent() {
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.publicFailureMessage(resultEvent: nil, stderrText: "fatal: model not found"),
                "fatal: model not found",
            )
        }

        func testPublicFailureMessageFallsBackToPlaceholderWhenBothEmpty() {
            XCTAssertEqual(
                ClaudeCLIProtocolGenerator.publicFailureMessage(resultEvent: nil, stderrText: ""),
                "no diagnostic detail available in the CLI's output",
            )
        }

        // MARK: - drainStreamJSONLines

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

        func testDrainStreamJSONLinesCapturesResultEventAlongsideFragments() {
            var buffer = makeBuffer(
                [
                    #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#,
                    #"{"type":"result","subtype":"error_max_turns","is_error":true,"errors":["Reached maximum number of turns (50)"]}"#,
                ],
                trailingNewline: true,
            )
            var resultEvent: ClaudeCLIProtocolGenerator.ResultEventInfo?
            let fragments = ClaudeCLIProtocolGenerator.drainStreamJSONLines(buffer: &buffer, resultEvent: &resultEvent)
            XCTAssertEqual(fragments, ["Hi"])
            XCTAssertEqual(
                resultEvent,
                ClaudeCLIProtocolGenerator.ResultEventInfo(
                    isError: true, errors: ["Reached maximum number of turns (50)"], result: nil, terminalReason: nil,
                ),
            )
        }

        // MARK: - generate() integration

        /// On a nonzero exit, the thrown error must carry the CLI's real
        /// failure reason, not an empty/uninformative stderr — the exact gap
        /// that left 8 real meetings with no clue why protocol generation
        /// failed (see PR #692). Sourced from the stream-json terminal
        /// `result` event (subtype stays "success" with `is_error: true` and
        /// `terminal_reason: "api_error"`, `result` holding the error
        /// sentence on an immediate API-error failure — the real CLI's own
        /// shape, confirmed against the installed binary and independently
        /// by the PR #710 reviewer), not from accumulated assistant content:
        /// a real auth failure on the first turn produces no content at all,
        /// only this terminal line.
        func testGenerateOnFailureSourcesMessageFromResultEvent() async throws {
            let script = try Self.makeFakeClaudeScript(
                body: """
                cat > /dev/null
                msg='Failed to authenticate. API Error: 401 API key is invalid.'
                printf '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","result":"%s"}\\n' "$msg"
                exit 1
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            do {
                _ = try await generator.generate(
                    transcript: "Speaker 1: hello", title: "Sync", diarized: false,
                )
                XCTFail("Expected generate() to throw")
            } catch let ProtocolError.cliFailed(code, message) {
                XCTAssertEqual(code, 1)
                XCTAssertEqual(message, "Failed to authenticate. API Error: 401 API key is invalid.")
            }
        }

        /// Degraded path, not representative of the real CLI (which always
        /// emits a terminal `result` line — see
        /// `ClaudeCLIProtocolGenerator.parseResultEvent`): no result event
        /// and no stderr. Must fall back to the fixed placeholder rather
        /// than the accumulated assistant text, which could be a complete
        /// generated protocol — the leak PR #692's 4th commit closed.
        func testGenerateOnFailureFallsBackToPlaceholderWhenNoResultEventOrStderr() async throws {
            let script = try Self.makeFakeClaudeScript(
                body: """
                cat > /dev/null
                printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}\\n'
                exit 1
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            do {
                _ = try await generator.generate(
                    transcript: "Speaker 1: hello", title: "Sync", diarized: false,
                )
                XCTFail("Expected generate() to throw")
            } catch let ProtocolError.cliFailed(code, message) {
                XCTAssertEqual(code, 1)
                XCTAssertEqual(message, "no diagnostic detail available in the CLI's output")
            }
        }

        /// The exact scenario the PR #710 review's third comment named
        /// directly: a result event that looks exactly like a real API-error
        /// failure (`is_error: true`, `result` holding plausible error-shaped
        /// text) but whose `terminal_reason` doesn't confirm it. Must still
        /// fall back to the placeholder rather than trust `result` — a
        /// future CLI version could set `is_error: true` for some other
        /// reason while `result` still carries generated content, and
        /// `terminal_reason` is the only thing standing between that and a
        /// `.public` content leak.
        func testGenerateOnFailureFallsBackToPlaceholderWhenTerminalReasonUnrecognized() async throws {
            let script = try Self.makeFakeClaudeScript(
                body: """
                cat > /dev/null
                printf '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"context_limit",'
                printf '"result":"looks like an error but is not confirmed as one"}\\n'
                exit 1
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            do {
                _ = try await generator.generate(
                    transcript: "Speaker 1: hello", title: "Sync", diarized: false,
                )
                XCTFail("Expected generate() to throw")
            } catch let ProtocolError.cliFailed(code, message) {
                XCTAssertEqual(code, 1)
                XCTAssertEqual(message, "no diagnostic detail available in the CLI's output")
            }
        }

        /// Writes a temporary executable `#!/bin/sh` script wrapping `body`
        /// and returns its absolute path. Caller deletes it.
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
