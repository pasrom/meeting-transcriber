#if !APPSTORE

    import Foundation
    import os

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ClaudeCLIProtocolGenerator")

    /// Keeping the meeting out of the Claude CLI's own session store.
    ///
    /// Left to itself the CLI saves every run as a session under
    /// `~/.claude/projects/<working directory>/`, and a session holds the
    /// whole prompt, which here is the meeting transcript. That is a second,
    /// unplanned copy of a confidential document in another program's folder,
    /// one per protocol since every run has a working directory of its own.
    /// `--no-session-persistence` stops it. What the flag still leaves behind,
    /// measured with CLI 2.1.289, is the project folder itself with an empty
    /// `memory` folder in it. `disableAutoMemoryVariable` keeps the CLI from
    /// creating that folder at all; `removeIfOnlyEmptyFolders` takes it away
    /// where a CLI creates it anyway.
    extension ClaudeCLIProtocolGenerator {
        static let noSessionPersistenceFlag = "--no-session-persistence"

        /// Turns the CLI's auto memory off for the run. Measured with CLI
        /// 2.1.312: with it set, neither the project folder nor its `memory`
        /// folder appears. Unlike the cleanup it also covers a `claude-*`
        /// wrapper that sets its own `CLAUDE_CONFIG_DIR`, as long as the
        /// wrapper passes its environment on. A CLI that does not know the
        /// variable ignores it.
        static let disableAutoMemoryVariable = "CLAUDE_CODE_DISABLE_AUTO_MEMORY"

        /// How long `--help` may take before the CLI is treated as one
        /// without the flag.
        static let helpProbeTimeoutSeconds: TimeInterval = 10

        /// Binaries seen to accept the flag, keyed by resolved path and name.
        /// Only a yes is remembered: a no is asked again on the next run, so
        /// updating an old CLI takes effect without restarting the app.
        private static let binariesAcceptingNoSessionPersistence = OSAllocatedUnfairLock<Set<String>>(initialState: [])

        /// Executable, arguments and environment for one run.
        static func launchConfiguration(
            claudeBin: String, anthropicAPIKey: String?,
        ) async -> (resolvedBin: String, arguments: [String], environment: [String: String]) {
            let resolvedBin = resolveClaudePath(claudeBin)
            let environment = buildEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                searchPaths: searchPaths,
                anthropicAPIKey: anthropicAPIKey,
            )
            let noSessionPersistence = await cliSupportsNoSessionPersistence(
                resolvedBin: resolvedBin, claudeBin: claudeBin, environment: environment,
            )
            let arguments = buildSubprocessArgs(
                claudeBin: claudeBin, resolvedBin: resolvedBin, noSessionPersistence: noSessionPersistence,
            )
            return (resolvedBin, arguments, environment)
        }

        /// How long a CLI sent SIGTERM may take to exit before it gets SIGKILL.
        static let terminationGraceSeconds: TimeInterval = 1

        /// Waits for a CLI that has been sent SIGTERM to exit, sending
        /// SIGKILL once `grace` has passed. A failed run waits here before
        /// its folders are removed, so that a CLI still shutting down cannot
        /// write into them, or recreate its project folder, afterwards.
        static func awaitExit(
            of process: Process, exited: AsyncStream<Void>, grace: TimeInterval = terminationGraceSeconds,
        ) async {
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            for await _ in exited {
                break
            }
        }

        /// Removes the run's working directory, and the CLI's project folder
        /// for it while that holds nothing but empty folders.
        static func removeRunFolders(workingDirectory: URL, projectFolder: URL?) {
            try? FileManager.default.removeItem(at: workingDirectory)
            if let projectFolder { removeIfOnlyEmptyFolders(projectFolder) }
        }

        /// Whether the installed CLI accepts `noSessionPersistenceFlag`, read
        /// from its `--help`. Asked rather than assumed because a CLI older
        /// than the flag rejects an unknown option and would fail every
        /// protocol. A help text that cannot be read counts as no, which
        /// keeps the behaviour from before the flag existed.
        static func cliSupportsNoSessionPersistence(
            resolvedBin: String, claudeBin: String, environment: [String: String],
        ) async -> Bool {
            let key = "\(resolvedBin)\u{0}\(claudeBin)"
            if binariesAcceptingNoSessionPersistence.withLock({ $0.contains(key) }) { return true }
            let help = await readHelp(resolvedBin: resolvedBin, claudeBin: claudeBin, environment: environment)
            let supported = help.map(helpListsNoSessionPersistence) ?? false
            if supported {
                binariesAcceptingNoSessionPersistence.withLock { _ = $0.insert(key) }
            } else {
                logger.warning(
                    "claude_cli_session_persistence_on helpRead=\(help != nil, privacy: .public) — the CLI keeps this run's session, transcript included",
                )
            }
            return supported
        }

        static func helpListsNoSessionPersistence(_ help: String) -> Bool {
            help.contains(noSessionPersistenceFlag)
        }

        /// The CLI's `--help` output, or nil when it could not be started or
        /// did not exit within `timeout`. Runs in a working directory of its
        /// own, like a real run, so the probe neither inherits the app's
        /// directory nor touches the one the real run is about to get.
        ///
        /// Output goes to a file in that directory rather than a pipe, and
        /// the wait is for the process to exit, bounded by `timeout`: a
        /// wrapper script that ignores SIGTERM, or leaves a child holding its
        /// output open, must not hold up the protocol. A probe that runs out
        /// of time is sent SIGTERM, then SIGKILL a second later, and is not
        /// waited for again.
        static func readHelp(
            resolvedBin: String,
            claudeBin: String,
            environment: [String: String],
            timeout: TimeInterval = helpProbeTimeoutSeconds,
        ) async -> String? {
            guard let directory = try? makeWorkingDirectory() else { return nil }
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputFile = directory.appendingPathComponent("help.txt")
            guard FileManager.default.createFile(atPath: outputFile.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: outputFile) else { return nil }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedBin)
            process.arguments = (resolvedBin == "/usr/bin/env" ? [claudeBin] : []) + ["--help"]
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            let exited = await runBounded(process, timeout: timeout)
            try? output.close()
            guard exited, let data = try? Data(contentsOf: outputFile) else { return nil }
            return String(bytes: data, encoding: .utf8)
        }

        /// Starts `process` and reports whether it exited within `timeout`.
        /// False also when it could not be started.
        private static func runBounded(_ process: Process, timeout: TimeInterval) async -> Bool {
            await withCheckedContinuation { continuation in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let finish: @Sendable (Bool) -> Void = { exited in
                    let first = resumed.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume(returning: exited) }
                }
                process.terminationHandler = { _ in finish(true) }
                do {
                    try process.run()
                } catch {
                    finish(false)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    finish(false)
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }

        /// The folder the CLI keeps for a run started in `workingDirectory`:
        /// `<config dir>/projects/<name>`, where the config dir is
        /// `CLAUDE_CONFIG_DIR` or `.claude` in the child's `HOME` (the app's
        /// home directory when the environment sets none), and the name is the directory's
        /// physical path with every character other than an ASCII letter or
        /// digit replaced by `-`. Nil when the path cannot be resolved.
        static func cliProjectFolder(workingDirectory: URL, environment: [String: String]) -> URL? {
            guard let resolved = realpath(workingDirectory.path, nil) else { return nil }
            defer { free(resolved) }
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: home).appendingPathComponent(".claude")
            return configDirectory
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectFolderName(forPath: String(cString: resolved)), isDirectory: true)
        }

        static func projectFolderName(forPath path: String) -> String {
            String(String.UnicodeScalarView(path.unicodeScalars.map { scalar in
                scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? scalar : "-"
            }))
        }

        /// Removes `folder` only while everything in it is an empty folder.
        /// A file anywhere below it, a session from a CLI without the flag
        /// for instance, keeps the whole folder: the CLI wrote it, and
        /// deleting it is not this app's call.
        ///
        /// The folders go one by one, deepest first, with `rmdir`, which
        /// refuses a folder that is not empty. A file the CLI writes after
        /// the check, while a timed-out run is still shutting down for
        /// instance, therefore keeps its folders instead of going with them.
        static func removeIfOnlyEmptyFolders(_ folder: URL) {
            let own = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard own?.isDirectory == true, own?.isSymbolicLink != true else { return }
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            ) else { return }
            var folders: [URL] = []
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { return }
                folders.append(item)
            }
            // The enumerator lists a folder before its contents.
            for item in folders.reversed() {
                _ = rmdir(item.path)
            }
            if rmdir(folder.path) != 0 {
                let code = errno
                logger.warning("claude_cli_project_folder_kept errno=\(code, privacy: .public)")
            }
        }
    }

#endif
