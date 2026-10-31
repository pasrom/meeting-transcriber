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
        /// A yes is remembered so that a later `--help` that times out cannot
        /// start a meeting without the flag; a no is asked again on the next
        /// run. A run refused the flag drops the yes.
        private static let binariesAcceptingNoSessionPersistence = OSAllocatedUnfairLock<Set<String>>(initialState: [])

        typealias LaunchConfiguration = (resolvedBin: String, arguments: [String], environment: [String: String])

        /// Executable, arguments and environment for one run. The flag goes
        /// in only when `--help` lists it, since a CLI older than the flag
        /// rejects it; a help text that cannot be read counts as no, which
        /// keeps the behaviour from before the flag existed.
        static func launchConfiguration(
            claudeBin: String, anthropicAPIKey: String?, helpTimeout: TimeInterval,
        ) async -> LaunchConfiguration {
            let resolvedBin = resolveClaudePath(claudeBin)
            let environment = buildEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                searchPaths: searchPaths,
                anthropicAPIKey: anthropicAPIKey,
            )
            let answer = await askNoSessionPersistence(
                resolvedBin: resolvedBin, claudeBin: claudeBin, environment: environment, helpTimeout: helpTimeout,
            )
            if answer != .listed, !Task.isCancelled {
                logger.warning(
                    "claude_cli_session_persistence_on helpRead=\(answer != .unread, privacy: .public) — the CLI keeps this run's session, transcript included",
                )
            }
            let arguments = buildSubprocessArgs(
                claudeBin: claudeBin, resolvedBin: resolvedBin, noSessionPersistence: answer == .listed,
            )
            return (resolvedBin, arguments, environment)
        }

        /// The launch for one more run after `failed` was refused the flag,
        /// or nil for none. Drops the remembered yes and asks `--help` again:
        /// only a help text that was read and does not list the flag earns a
        /// run without it, with the same executable and environment.
        static func launchWithoutRejectedFlag(
            after failed: LaunchConfiguration, claudeBin: String, helpTimeout: TimeInterval,
        ) async -> LaunchConfiguration? {
            let key = cacheKey(resolvedBin: failed.resolvedBin, claudeBin: claudeBin)
            _ = binariesAcceptingNoSessionPersistence.withLock { $0.remove(key) }
            let answer = await askNoSessionPersistence(
                resolvedBin: failed.resolvedBin, claudeBin: claudeBin, environment: failed.environment,
                helpTimeout: helpTimeout,
            )
            logger.warning(
                "claude_cli_rejected_no_session_persistence help=\(String(describing: answer), privacy: .public) retry=\(answer == .notListed, privacy: .public)",
            )
            guard answer == .notListed else { return nil }
            let arguments = buildSubprocessArgs(
                claudeBin: claudeBin, resolvedBin: failed.resolvedBin, noSessionPersistence: false,
            )
            return (failed.resolvedBin, arguments, failed.environment)
        }

        private static func cacheKey(resolvedBin: String, claudeBin: String) -> String {
            "\(resolvedBin)\u{0}\(claudeBin)"
        }

        /// What `--help` says about the flag.
        enum HelpAnswer {
            case listed
            case notListed
            /// The help could not be read, so it says nothing either way.
            case unread
        }

        /// What the CLI's `--help` says about the flag, or the remembered yes.
        private static func askNoSessionPersistence(
            resolvedBin: String, claudeBin: String, environment: [String: String], helpTimeout: TimeInterval,
        ) async -> HelpAnswer {
            let key = cacheKey(resolvedBin: resolvedBin, claudeBin: claudeBin)
            if binariesAcceptingNoSessionPersistence.withLock({ $0.contains(key) }) { return .listed }
            let help = await readHelp(
                resolvedBin: resolvedBin, claudeBin: claudeBin, environment: environment, timeout: helpTimeout,
            )
            // A probe ended by a cancelled job says nothing about the CLI;
            // the job ends right after.
            guard let help, !Task.isCancelled else { return .unread }
            guard helpListsNoSessionPersistence(help) else { return .notListed }
            _ = binariesAcceptingNoSessionPersistence.withLock { $0.insert(key) }
            return .listed
        }

        /// A failed run whose CLI refused the flag. `error` is what the run
        /// reports when there is no second run.
        struct NoSessionPersistenceRejected: Error {
            let error: ProtocolError
        }

        /// Whether a run given the flag was refused it: a line of its stderr
        /// or reported message names the flag together with unknown-option
        /// wording, ignoring case. Both are read because the message prefers
        /// a result event's reason over stderr.
        static func rejectedNoSessionPersistence(stderr: String, message: String, arguments: [String]) -> Bool {
            guard arguments.contains(noSessionPersistenceFlag) else { return false }
            let wordings = ["unknown option", "unrecognized option", "unrecognised option", "invalid option"]
            return [stderr, message].contains { text in
                text.split(whereSeparator: \.isNewline).contains { line in
                    let line = line.lowercased()
                    return line.contains(noSessionPersistenceFlag) && wordings.contains { line.contains($0) }
                }
            }
        }

        /// Removes the run's working directory, and the CLI's project folder
        /// for it while that holds nothing but empty folders.
        static func removeRunFolders(workingDirectory: URL, projectFolder: URL?) {
            try? FileManager.default.removeItem(at: workingDirectory)
            if let projectFolder { removeIfOnlyEmptyFolders(projectFolder) }
        }

        static func helpListsNoSessionPersistence(_ help: String) -> Bool {
            help.contains(noSessionPersistenceFlag)
        }

        /// The CLI's `--help` output, or nil when it could not be started or
        /// did not exit within `timeout`. Runs in a working directory of its
        /// own, like a real run, so the probe neither inherits the app's
        /// directory nor touches the one the real run is about to get.
        ///
        /// Output goes to a file in that directory rather than a pipe, so a
        /// child of the CLI holding its output open cannot hold up the
        /// protocol. A probe still running at `timeout` is stopped (SIGTERM,
        /// then SIGKILL after the termination grace) and its exit awaited
        /// before the directory is removed, so the probe takes at most
        /// `timeout` plus that grace. Cancellation stops it the same way.
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

            let outcome = try? await BoundedProcess(process).run(timeout: timeout)
            try? output.close()
            guard case .exited = outcome, let data = try? Data(contentsOf: outputFile) else { return nil }
            return String(bytes: data, encoding: .utf8)
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
