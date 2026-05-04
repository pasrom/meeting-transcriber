#if !APPSTORE

    import Foundation
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ClaudeCLIProtocolGenerator")

    /// Claude CLI implementation that generates protocols via subprocess.
    struct ClaudeCLIProtocolGenerator: ProtocolGenerating {
        let claudeBin: String
        let language: String

        static let timeoutSeconds: TimeInterval = 600

        /// Search paths for Claude CLI binaries.
        static let searchPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "/opt/homebrew/bin",
        ]

        // MARK: - ProtocolGenerating

        func generate(transcript: String, title _: String, diarized: Bool) async throws -> String {
            var prompt = ProtocolGenerator.applyLanguage(ProtocolGenerator.loadPrompt(), language: language)
            if diarized {
                prompt += ProtocolGenerator.diarizationNote
            }
            prompt += transcript

            let process = Process()
            let resolvedBin = Self.resolveClaudePath(claudeBin)
            process.executableURL = URL(fileURLWithPath: resolvedBin)
            var args = ["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet"]
            // If using /usr/bin/env fallback, prepend the binary name
            if resolvedBin == "/usr/bin/env" {
                args.insert(claudeBin, at: 0)
            }
            process.arguments = args

            // Remove CLAUDECODE env var to allow nested Claude CLI invocation
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            // App bundles have a minimal PATH — ensure common bin dirs are included
            // so wrapper scripts (e.g. claude-work-wrapper calling `exec claude`) work
            let extraPaths = Self.searchPaths.joined(separator: ":")
            env["PATH"] = "\(extraPaths):\(env["PATH"] ?? "/usr/bin:/bin")"
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // C5 fix: Set terminationHandler BEFORE process.run() to avoid race
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

            // C5 fix: Guard against process having already exited before we awaited.
            // If the process already exited, terminationHandler may have already fired,
            // but AsyncStream buffers the yield so we won't miss it.
            // No additional check needed — AsyncStream handles the race.

            // C6 fix: Write stdin in a detached task to avoid deadlock on large transcripts.
            // The pipe buffer is finite (~64KB); if the prompt exceeds it, a synchronous
            // write blocks until the reader drains — but we haven't started reading yet.
            let promptData = Data(prompt.utf8)
            logger.info("claude_cli_subprocess_start prompt_bytes=\(promptData.count, privacy: .public)")
            let stdinWriteTask = Task.detached {
                stdinPipe.fileHandleForWriting.write(promptData)
                stdinPipe.fileHandleForWriting.closeFile()
            }

            // Read stream-json output concurrently with stdin write
            let text = try await Self.readStreamJSON(from: stdoutPipe, process: process)

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
                let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                logger.error(
                    "claude_cli_failed exit=\(process.terminationStatus, privacy: .public) stderr=\(stderrText, privacy: .public)",
                )
                throw ProtocolError.cliFailed(Int(process.terminationStatus), stderrText)
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                logger.error("claude_cli_empty_response — subprocess exited 0 with empty output")
                throw ProtocolError.emptyProtocol
            }

            return trimmed
        }

        // MARK: - Stream JSON

        /// Parse Claude CLI stream-json output and accumulate text.
        private static func readStreamJSON(from pipe: Pipe, process: Process) async throws -> String {
            let handle = pipe.fileHandleForReading
            var parts: [String] = []
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

                // I1 fix: Wrap blocking availableData in Task.detached to avoid
                // blocking Swift's cooperative thread pool. availableData blocks
                // until data is available or EOF, which would starve other tasks.
                let chunk = await Task.detached { handle.availableData }.value
                if chunk.isEmpty { break } // EOF

                buffer.append(chunk)

                // Process complete lines
                while let newlineRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer[buffer.startIndex ..< newlineRange.lowerBound]
                    buffer.removeSubrange(buffer.startIndex ... newlineRange.lowerBound)

                    guard let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !line.isEmpty else { continue }

                    if let text = parseStreamJSONLine(line) {
                        parts.append(text)
                    }
                }
            }

            return parts.joined()
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
    }

#endif
