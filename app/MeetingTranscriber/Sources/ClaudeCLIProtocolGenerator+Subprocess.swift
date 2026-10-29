#if !APPSTORE

    import Foundation
    import os

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ClaudeCLIProtocolGenerator")

    /// One run of the CLI: its pipes and its bounded lifetime.
    ///
    /// stdout and stderr are read through readability handlers feeding
    /// streams, with no thread blocked in a read, because a process the CLI
    /// started can hold them open after the CLI has gone. Each stream ends at
    /// end of file or `outputDrainGrace` after the CLI exits, whichever comes
    /// first. The prompt goes to stdin through a dispatch channel that is
    /// stopped with the CLI and when the run ends, so a CLI that never reads
    /// it cannot hold up the run either.
    extension ClaudeCLIProtocolGenerator {
        /// Default for `outputDrainGrace`: how long the CLI's output is still
        /// read after it has exited. What it wrote before exiting is in the
        /// pipe by then; this only matters when end of file does not come.
        static let outputDrainGraceSeconds: TimeInterval = 1

        /// How much of the end of stderr is kept for the failure message.
        static let stderrTailBytes = 64 * 1024

        /// What a run that ended by itself left behind.
        struct RunOutput {
            let text: String
            let resultEvent: ResultEventInfo?
            let exitCode: Int32
            let stderrData: Data
        }

        /// Runs the CLI set up in `process` with `prompt` on its stdin.
        /// Throws `ProtocolError.timeout` when it had to be stopped at
        /// `timeout`, `CancellationError` when cancelled, and
        /// `ProtocolError.cliNotFound` when it cannot be started. Neither
        /// returns nor throws while the CLI is still running, so the caller
        /// can remove the run's folders right afterwards.
        func runCLI(_ process: Process, prompt: String) async throws -> RunOutput {
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let stdout = Self.outputChunks(of: stdoutPipe)
            let stderr = Self.outputChunks(of: stderrPipe)
            let endOutput: @Sendable () -> Void = {
                _ = stdout.end()
                _ = stderr.end()
            }
            async let read = Self.readStreamJSON(from: stdout.chunks)
            async let stderrTail = Self.collectTail(of: stderr.chunks, limit: Self.stderrTailBytes)

            let stdin = Self.writePrompt(prompt, to: stdinPipe)
            defer { stdin.close(flags: .stop) }
            let outcome: BoundedProcess.Outcome
            do {
                outcome = try await BoundedProcess(process, terminationGrace: terminationGrace)
                    .run(timeout: timeout) { stdin.close(flags: .stop) }
            } catch is CancellationError {
                // The output stopped being read when the cancellation came,
                // so a CLI writing more than a pipe buffer while it shuts
                // down blocks until the SIGKILL. Acceptable on this path.
                endOutput()
                throw CancellationError()
            } catch {
                endOutput()
                logger.error(
                    "claude_cli_not_found bin=\(claudeBin, privacy: .public) resolvedPath=\(process.executableURL?.path ?? "", privacy: .public) error=\(error.localizedDescription, privacy: .public)",
                )
                throw ProtocolError.cliNotFound(claudeBin)
            }
            guard case let .exited(exitCode) = outcome else {
                endOutput()
                let limit = String(format: "%.1f", timeout)
                logger.error("claude_cli_timeout limit=\(limit, privacy: .public)s")
                throw ProtocolError.timeout
            }

            let drainGrace = outputDrainGrace
            DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) {
                let stdoutCut = stdout.end()
                let stderrCut = stderr.end()
                guard stdoutCut || stderrCut else { return }
                // Output may be missing from here on: a process the CLI
                // started still held the pipe when the drain grace ran out.
                logger.warning(
                    "claude_cli_output_cut_after_exit stdout=\(stdoutCut, privacy: .public) stderr=\(stderrCut, privacy: .public) grace=\(drainGrace, privacy: .public)s",
                )
            }
            let (text, resultEvent) = await read
            let stderrData = await stderrTail
            try Task.checkCancellation()
            return RunOutput(text: text, resultEvent: resultEvent, exitCode: exitCode, stderrData: stderrData)
        }

        /// What the CLI writes to `pipe`, chunk by chunk as it arrives. The
        /// stream ends at end of file, or earlier when `end` is called, which
        /// reports whether it was the one to end it (end of file had not
        /// come). Either way the handler is removed.
        static func outputChunks(of pipe: Pipe) -> (chunks: AsyncStream<Data>, end: @Sendable () -> Bool) {
            let (chunks, continuation) = AsyncStream<Data>.makeStream()
            let open = OSAllocatedUnfairLock(initialState: true)
            let end: @Sendable () -> Bool = {
                let wasOpen = open.withLock { isOpen in
                    defer { isOpen = false }
                    return isOpen
                }
                continuation.finish()
                return wasOpen
            }
            let handle = pipe.fileHandleForReading
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
            handle.readabilityHandler = { readable in
                let data = readable.availableData
                if data.isEmpty {
                    _ = end()
                } else {
                    continuation.yield(data)
                }
            }
            return (chunks, end)
        }

        /// The last `limit` bytes of `chunks`, starting on a UTF-8 character
        /// boundary. Trimmed only once twice the limit has piled up, so a
        /// long stream is not copied on every chunk.
        static func collectTail(of chunks: AsyncStream<Data>, limit: Int) async -> Data {
            var data = Data()
            for await chunk in chunks {
                data.append(chunk)
                if data.count > 2 * limit { data = tail(of: data, limit: limit) }
            }
            return data.count > limit ? tail(of: data, limit: limit) : data
        }

        private static func tail(of data: Data, limit: Int) -> Data {
            Data(data.suffix(limit).drop { $0 & 0xC0 == 0x80 })
        }

        /// Writes the prompt to the CLI's stdin and closes it, through a
        /// dispatch channel, so no thread blocks while a prompt larger than
        /// the pipe buffer (~64KB) waits for the CLI to read it. Closing the
        /// returned channel with `.stop` abandons what is not yet written.
        /// SIGPIPE is off for the descriptor: a CLI gone before reading its
        /// prompt fails the write with EPIPE instead of ending the app.
        private static func writePrompt(_ prompt: String, to pipe: Pipe) -> DispatchIO {
            let handle = pipe.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: .global()) { _ in
                try? handle.close()
            }
            var prompt = prompt
            let data = prompt.withUTF8 { DispatchData(bytes: UnsafeRawBufferPointer($0)) }
            logger.info("claude_cli_subprocess_start prompt_bytes=\(data.count, privacy: .public)")
            channel.write(offset: 0, data: data, queue: .global()) { done, _, error in
                guard done else { return }
                if error != 0 {
                    logger.debug("claude_cli_stdin_write_failed errno=\(error, privacy: .public)")
                }
                channel.close()
            }
            return channel
        }
    }

#endif
