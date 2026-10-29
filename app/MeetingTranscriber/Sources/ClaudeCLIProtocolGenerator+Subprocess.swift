#if !APPSTORE

    import Foundation
    import os

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ClaudeCLIProtocolGenerator")

    /// One run of the CLI: its pipes and its bounded lifetime.
    ///
    /// stdout and stderr are read through `ProcessOutput`, so each ends at
    /// end of file or `outputDrainGrace` after the CLI exits, whichever comes
    /// first, and only the end of stderr is kept. The prompt goes to stdin
    /// through a dispatch channel that is stopped with the CLI and when the
    /// run ends, so a CLI that never reads it cannot hold up the run either.
    extension ClaudeCLIProtocolGenerator {
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
            let stdout = ProcessOutput.chunks(of: stdoutPipe)
            let stderr = ProcessOutput.chunks(of: stderrPipe)

            let stdin = Self.writePrompt(prompt, to: stdinPipe)
            defer { stdin.close(flags: .stop) }
            let drainGrace = outputDrainGrace
            let run: (outcome: BoundedProcess.Outcome, output: (text: String, resultEvent: ResultEventInfo?, stderr: Data))
            do {
                run = try await ProcessOutput.run(
                    BoundedProcess(process, terminationGrace: terminationGrace),
                    timeout: timeout,
                    onStop: { stdin.close(flags: .stop) },
                    ending: [stdout.end, stderr.end],
                    drainGrace: drainGrace,
                    onCut: { cut in
                        // Output may be missing from here on: a process the
                        // CLI started still held the pipe when the drain
                        // grace ran out.
                        logger.warning(
                            "claude_cli_output_cut_after_exit stdout=\(cut[0], privacy: .public) stderr=\(cut[1], privacy: .public) grace=\(drainGrace, privacy: .public)s",
                        )
                    },
                    read: {
                        async let stdoutRead = Self.readStreamJSON(from: stdout.chunks)
                        async let tail = ProcessOutput.collectTail(of: stderr.chunks)
                        let (text, resultEvent) = await stdoutRead
                        return await (text, resultEvent, tail)
                    },
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                logger.error(
                    "claude_cli_not_found bin=\(claudeBin, privacy: .public) resolvedPath=\(process.executableURL?.path ?? "", privacy: .public) error=\(error.localizedDescription, privacy: .public)",
                )
                throw ProtocolError.cliNotFound(claudeBin)
            }
            guard case let .exited(exitCode) = run.outcome else {
                let limit = BoundedProcess.label(for: timeout)
                logger.error("claude_cli_timeout limit=\(limit, privacy: .public)s")
                throw ProtocolError.timeout
            }
            return RunOutput(
                text: run.output.text, resultEvent: run.output.resultEvent,
                exitCode: exitCode, stderrData: run.output.stderr,
            )
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
