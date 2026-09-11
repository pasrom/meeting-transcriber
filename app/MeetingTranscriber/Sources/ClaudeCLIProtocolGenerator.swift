#if !APPSTORE

    import Foundation
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ClaudeCLIProtocolGenerator")

    /// Claude CLI implementation that generates protocols via subprocess.
    struct ClaudeCLIProtocolGenerator: ProtocolGenerating {
        let claudeBin: String
        let language: String

        /// User-supplied key from Settings → Protocol Generation (`AppSettings.claudeAPIKey`),
        /// injected only when the user has explicitly typed one in. Not
        /// auto-discovered: an implicit switch away from the CLI's own OAuth
        /// login would silently move a healthy subscription session onto
        /// metered billing, and a stale/wrong key would silently break a
        /// previously-working install (both measured — see PR #692 review).
        let anthropicAPIKey: String?

        init(claudeBin: String, language: String, anthropicAPIKey: String? = nil) {
            self.claudeBin = claudeBin
            self.language = language
            self.anthropicAPIKey = anthropicAPIKey
        }

        static let timeoutSeconds: TimeInterval = 600

        /// Search paths for Claude CLI binaries.
        static let searchPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "/opt/homebrew/bin",
        ]

        // MARK: - ProtocolGenerating

        func generate(
            transcript: String,
            title _: String,
            diarized: Bool,
            meetingStartTime: Date?,
        ) async throws -> String {
            let prompt = ProtocolGenerator.buildSystemPrompt(diarized: diarized, language: language, meetingStartTime: meetingStartTime) + transcript

            let process = Process()
            let resolvedBin = Self.resolveClaudePath(claudeBin)
            process.executableURL = URL(fileURLWithPath: resolvedBin)
            process.arguments = Self.buildSubprocessArgs(claudeBin: claudeBin, resolvedBin: resolvedBin)
            process.environment = Self.buildEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                searchPaths: Self.searchPaths,
                anthropicAPIKey: anthropicAPIKey,
            )

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Set terminationHandler BEFORE process.run() to avoid race
            // where the process exits before the handler is installed.
            // AsyncStream buffers the yield, so even if the process exits before
            // we iterate, the value is not lost.
            let exitStream = AsyncStream<Void> { continuation in
                process.terminationHandler = { _ in
                    continuation.yield()
                    continuation.finish()
                }
            }

            do {
                try process.run()
            } catch {
                logger.error(
                    "claude_cli_not_found bin=\(self.claudeBin, privacy: .public) resolvedPath=\(resolvedBin, privacy: .public) error=\(error.localizedDescription, privacy: .public)",
                )
                throw ProtocolError.cliNotFound(claudeBin)
            }

            // Guard against process having already exited before we awaited.
            // If the process already exited, terminationHandler may have already fired,
            // but AsyncStream buffers the yield so we won't miss it.
            // No additional check needed — AsyncStream handles the race.

            // Write stdin in a detached task to avoid deadlock on large transcripts.
            // The pipe buffer is finite (~64KB); if the prompt exceeds it, a synchronous
            // write blocks until the reader drains — but we haven't started reading yet.
            let promptData = Data(prompt.utf8)
            logger.info("claude_cli_subprocess_start prompt_bytes=\(promptData.count, privacy: .public)")
            let stdinWriteTask = Task.detached {
                // Use the throwing `write(contentsOf:)` rather than the deprecated
                // `write(_:)`: the latter raises an uncatchable Obj-C NSException on
                // a write error (e.g. EPIPE when the child's stdin read end has
                // closed — which happens on the timeout path where readStreamJSON
                // calls process.terminate()), aborting the whole app. The throwing
                // API turns a broken pipe into a handled Swift error so we can log
                // and fall through to close the handle. Mirrors the write sites in
                // RecognitionStats and PersistentDiagnosticLog.
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: promptData)
                } catch {
                    logger.debug(
                        "claude_cli_stdin_write_failed error=\(error.localizedDescription, privacy: .public)",
                    )
                }
                try? stdinPipe.fileHandleForWriting.close()
            }

            // Read stream-json output concurrently with stdin write
            let (text, resultEvent) = try await Self.readStreamJSON(from: stdoutPipe, process: process)

            // Ensure stdin write completes (should be done by now)
            _ = await stdinWriteTask.value

            // Read stderr in background to prevent pipe buffer issues
            async let stderrRead = Task.detached {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }.value

            // Await process exit via the stream installed before launch
            for await _ in exitStream {
                break
            }

            if process.terminationStatus != 0 {
                let stderrData = await stderrRead
                throw Self.handleFailure(
                    exitCode: process.terminationStatus, stderrData: stderrData, text: text, resultEvent: resultEvent,
                )
            }

            return try Self.validateGeneratedText(text)
        }

        /// Pair an already-decoded stderr string with `exitCode` as a
        /// `ProtocolError.cliFailed`.
        static func makeFailureError(exitCode: Int32, stderrText: String) -> ProtocolError {
            .cliFailed(Int(exitCode), stderrText)
        }

        /// Decodes `stderrData`, logs the raw exit/stderr/text, and builds the
        /// error `generate()` throws on a nonzero exit — pulled out of
        /// `generate()` itself to keep that function's body short.
        static func handleFailure(
            exitCode: Int32, stderrData: Data, text: String, resultEvent: ResultEventInfo?,
        ) -> ProtocolError {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The accumulated text is a complete generated protocol on any run
            // that got far enough to produce one (the CLI runs without
            // --include-partial-messages, so only whole assistant messages are
            // ever emitted) — never safe to log at .public. Kept .private,
            // unchanged from the redaction in PR #692's 4th commit.
            logger.error(
                "claude_cli_failed exit=\(exitCode, privacy: .public) stderr=\(stderrText, privacy: .public) text=\(text, privacy: .private)",
            )
            // The terminal result event's own error fields are CLI-authored
            // diagnostic metadata, never generated content by construction —
            // restores the .public visibility PR #692 traded away, for
            // cliFailed AND (via PipelineQueue+Stages.swift's shared catch-all
            // log site) for cliNotFound/timeout/emptyProtocol/OpenAI-provider
            // failures too, none of which ever carried content in the first
            // place.
            let publicMessage = publicFailureMessage(resultEvent: resultEvent, stderrText: stderrText)
            logger.error(
                "claude_cli_failed_reason exit=\(exitCode, privacy: .public) reason=\(publicMessage, privacy: .public)",
            )
            return makeFailureError(exitCode: exitCode, stderrText: publicMessage)
        }

        /// The message surfaced to the user and logged at `.public`. Prefers
        /// the result event's own error text (see `resultEventFailureReason`
        /// — never generated content); then real stderr output (also always
        /// safe — stderr can be empty for a given failure, but never unsafe);
        /// then a fixed placeholder. Deliberately does NOT fall back to the
        /// accumulated `text` — that would reopen the leak PR #692's 4th
        /// commit closed, for the sake of a case not yet observed in
        /// practice (a nonzero exit whose terminal result event carries no
        /// error markers at all).
        static func publicFailureMessage(resultEvent: ResultEventInfo?, stderrText: String) -> String {
            if let reason = resultEventFailureReason(resultEvent) { return reason }
            if !stderrText.isEmpty { return stderrText }
            return "no diagnostic detail available in the CLI's output"
        }

        /// Trim whitespace from CLI output. Throws `.emptyProtocol` when
        /// the subprocess exited successfully but produced no usable text.
        static func validateGeneratedText(_ text: String) throws -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProtocolError.emptyProtocol }
            return trimmed
        }

        // MARK: - Stream JSON

        /// Parse Claude CLI stream-json output, accumulate text, and capture
        /// the terminal `result` event (if any) for failure diagnostics.
        private static func readStreamJSON(
            from pipe: Pipe, process: Process,
        ) async throws -> (text: String, resultEvent: ResultEventInfo?) {
            let handle = pipe.fileHandleForReading
            var parts: [String] = []
            var resultEvent: ResultEventInfo?
            let startTime = ProcessInfo.processInfo.systemUptime

            // Read line-by-line from stdout
            var buffer = Data()
            while true {
                if ProcessInfo.processInfo.systemUptime - startTime > timeoutSeconds {
                    let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                    let elapsedStr = String(format: "%.1f", elapsed)
                    logger.error(
                        "claude_cli_timeout elapsed=\(elapsedStr, privacy: .public)s parts_received=\(parts.count, privacy: .public)",
                    )
                    process.terminate()
                    throw ProtocolError.timeout
                }

                // Wrap blocking availableData in Task.detached to avoid
                // blocking Swift's cooperative thread pool. availableData blocks
                // until data is available or EOF, which would starve other tasks.
                let chunk = await Task.detached { handle.availableData }.value
                if chunk.isEmpty { break } // EOF

                buffer.append(chunk)
                parts.append(contentsOf: drainStreamJSONLines(buffer: &buffer, resultEvent: &resultEvent))
            }

            return (parts.joined(), resultEvent)
        }

        /// Drain every newline-terminated line currently in `buffer`, parsing
        /// each via `parseStreamJSONLine`. Returns the extracted text
        /// fragments in order. Lines that are empty after trimming, lines
        /// that don't decode as UTF-8, and lines that `parseStreamJSONLine`
        /// rejects are silently skipped. Also captures the last-seen
        /// terminal `result` event (there is only ever one per run) into
        /// `resultEvent` for the caller to read once streaming ends.
        ///
        /// Trailing bytes without a terminating newline stay in `buffer`
        /// for the next call to consume — the caller must keep the buffer
        /// across iterations.
        static func drainStreamJSONLines(buffer: inout Data, resultEvent: inout ResultEventInfo?) -> [String] {
            var fragments: [String] = []
            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex ..< newlineIdx]
                buffer.removeSubrange(buffer.startIndex ... newlineIdx)

                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !line.isEmpty else { continue }

                if let text = parseStreamJSONLine(line) {
                    fragments.append(text)
                }
                if let parsed = parseResultEvent(line) {
                    resultEvent = parsed
                }
            }
            return fragments
        }

        /// Parse a single stream-json line and extract text content.
        static func parseStreamJSONLine(_ line: String) -> String? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // content_block_delta carries streaming text chunks
            if obj["type"] as? String == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return text
            }

            // assistant message carries the final full text
            if obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "text",
                       let text = block["text"] as? String {
                        return text
                    }
                }
            }

            return nil
        }

        /// Content-free diagnostic fields read from a stream-json terminal
        /// `result` event. Unlike the accumulated assistant `text` (a
        /// complete generated protocol on any run that produced one), `errors`
        /// and `terminalReason` are CLI-authored metadata about the run
        /// itself and never carry meeting content, by construction — safe to
        /// log at `.public`.
        ///
        /// `result` is NOT safe on its own: it is a dual-purpose field that
        /// holds the generated protocol on a normal completion and the
        /// error sentence on an in-turn API-error failure (e.g. an expired
        /// OAuth session), and `subtype` reads `"success"` in both cases —
        /// `isError` alone does not prove which one a given event is, only
        /// that the CLI currently behaves this way (undocumented upstream,
        /// github.com/anthropics/claude-code#24612; confirmed against real
        /// runs, both by us and independently by the PR #710 reviewer).
        /// `resultEventFailureReason` additionally requires `terminalReason
        /// == "api_error"` before trusting `result`, so a future CLI version
        /// that ever sets `isError: true` with `result` still holding content
        /// fails closed to the caller's placeholder instead of logging it.
        struct ResultEventInfo: Equatable {
            let isError: Bool
            let errors: [String]
            let result: String?
            let terminalReason: String?
        }

        /// Parse a stream-json terminal `result` line. Returns nil for every
        /// other event type or malformed JSON. `errors` (the structural-
        /// failure shape — error_during_execution, error_max_turns,
        /// error_max_budget_usd, error_max_structured_output_retries) and
        /// `result` (the success shape, which the CLI also uses — with
        /// `is_error: true` — when a run fails immediately with an API
        /// error, e.g. an expired OAuth session or an invalid key on the
        /// first turn) are the two shapes observed in the wild; both are
        /// read defensively since this format is undocumented upstream
        /// (github.com/anthropics/claude-code#24612) and could change.
        /// `terminal_reason` (e.g. `"api_error"`, `"completed"`,
        /// `"max_turns"`) is the CLI's own classification of why the turn
        /// ended — see `ResultEventInfo`'s doc comment for why
        /// `resultEventFailureReason` checks it before trusting `result`.
        static func parseResultEvent(_ line: String) -> ResultEventInfo? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "result" else {
                return nil
            }
            let isError = obj["is_error"] as? Bool ?? false
            let errors = (obj["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
            let result = obj["result"] as? String
            let terminalReason = obj["terminal_reason"] as? String
            return ResultEventInfo(isError: isError, errors: errors, result: result, terminalReason: terminalReason)
        }

        /// The CLI's own diagnostic sentence for a failed run, sourced from
        /// the terminal `result` event rather than the accumulated assistant
        /// text. Prefers `errors` (joined — always content-free, see
        /// `ResultEventInfo`). Falls back to `result` only when `isError` is
        /// set AND `terminalReason == "api_error"` — the one CLI-classified
        /// reason observed to put its error sentence in the dual-purpose
        /// `result` field rather than `errors`. Any other or missing
        /// `terminalReason` fails closed to nil rather than risk trusting
        /// `result` while it might hold generated content. Returns nil when
        /// the event is absent or carries nothing usable.
        static func resultEventFailureReason(_ resultEvent: ResultEventInfo?) -> String? {
            guard let resultEvent, resultEvent.isError else { return nil }
            if !resultEvent.errors.isEmpty {
                return resultEvent.errors.joined(separator: "; ")
            }
            guard resultEvent.terminalReason == "api_error" else { return nil }
            if let result = resultEvent.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                return result
            }
            return nil
        }

        // MARK: - CLI Resolution

        /// Scan known install locations for executables starting with "claude".
        /// Always includes "claude" as a fallback even if not found.
        static func availableClaudeBinaries() -> [String] {
            let fm = FileManager.default
            var names = Set<String>()

            for dir in searchPaths {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasPrefix("claude") {
                    let full = "\(dir)/\(entry)"
                    if fm.isExecutableFile(atPath: full) {
                        names.insert(entry)
                    }
                }
            }

            names.insert("claude")
            return names.sorted()
        }

        /// Resolve the claude CLI binary path.
        /// App bundles have a restricted PATH, so check common install locations.
        static func resolveClaudePath(_ bin: String) -> String {
            // If already an absolute path, use it
            if bin.hasPrefix("/") { return bin }

            for path in searchPaths.map({ "\($0)/\(bin)" })
                where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            // Fallback: hope it's in PATH
            return "/usr/bin/env"
        }

        // MARK: - Pure subprocess builders

        /// Build the CLI argument vector. When `resolvedBin` is the
        /// `/usr/bin/env` fallback, prepend `claudeBin` so env can resolve
        /// it from PATH.
        static func buildSubprocessArgs(claudeBin: String, resolvedBin: String) -> [String] {
            var args = ["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet"]
            if resolvedBin == "/usr/bin/env" {
                args.insert(claudeBin, at: 0)
            }
            return args
        }

        /// Strip `CLAUDECODE` (avoid nested-session detection by the child
        /// CLI) and prepend `searchPaths` to `PATH` (app bundles inherit
        /// a minimal `PATH`). `anthropicAPIKey`, when non-empty and not
        /// already set in `baseEnvironment`, is injected so the subprocess
        /// can authenticate via API key instead of the CLI's own OAuth
        /// session. The key is never auto-discovered — it only arrives here
        /// when the user has explicitly typed one into Settings → Protocol
        /// Generation (`AppSettings.claudeAPIKey`), so a healthy OAuth
        /// session is never silently switched to metered billing and a bad
        /// key can never silently break a previously-working install.
        static func buildEnvironment(
            baseEnvironment: [String: String],
            searchPaths: [String],
            anthropicAPIKey: String? = nil,
        ) -> [String: String] {
            var env = baseEnvironment
            env.removeValue(forKey: "CLAUDECODE")
            let extraPaths = searchPaths.joined(separator: ":")
            env["PATH"] = "\(extraPaths):\(env["PATH"] ?? "/usr/bin:/bin")"
            if env["ANTHROPIC_API_KEY"]?.isEmpty ?? true,
               let anthropicAPIKey, !anthropicAPIKey.isEmpty {
                env["ANTHROPIC_API_KEY"] = anthropicAPIKey
            }
            return env
        }
    }

#endif
