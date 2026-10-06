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
    /// `memory` folder in it; `removeIfOnlyEmptyFolders` takes that away.
    extension ClaudeCLIProtocolGenerator {
        static let noSessionPersistenceFlag = "--no-session-persistence"

        /// How long `--help` may take before the CLI is treated as one
        /// without the flag.
        static let helpProbeTimeoutSeconds: TimeInterval = 10

        /// Binaries seen to accept the flag, keyed by resolved path and name.
        /// Only a yes is remembered: a no is asked again on the next run, so
        /// updating an old CLI takes effect without restarting the app.
        private static let binariesWithoutSessionPersistence = OSAllocatedUnfairLock<Set<String>>(initialState: [])

        /// Whether the installed CLI accepts `noSessionPersistenceFlag`, read
        /// from its `--help`. Asked rather than assumed because a CLI older
        /// than the flag rejects an unknown option and would fail every
        /// protocol. A help text that cannot be read counts as no, which
        /// keeps the behaviour from before the flag existed.
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

        /// Removes the run's working directory, and the CLI's project folder
        /// for it while that holds nothing but empty folders.
        static func removeRunFolders(workingDirectory: URL, projectFolder: URL?) {
            try? FileManager.default.removeItem(at: workingDirectory)
            if let projectFolder { removeIfOnlyEmptyFolders(projectFolder) }
        }

        static func cliSupportsNoSessionPersistence(
            resolvedBin: String, claudeBin: String, environment: [String: String],
        ) async -> Bool {
            let key = "\(resolvedBin)\u{0}\(claudeBin)"
            if binariesWithoutSessionPersistence.withLock({ $0.contains(key) }) { return true }
            let help = await readHelp(resolvedBin: resolvedBin, claudeBin: claudeBin, environment: environment)
            let supported = help.map(helpListsNoSessionPersistence) ?? false
            if supported {
                binariesWithoutSessionPersistence.withLock { _ = $0.insert(key) }
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

        /// The CLI's `--help` output, or nil when it could not be started.
        /// Runs in a working directory of its own, like a real run, so the
        /// probe neither inherits the app's directory nor touches the one
        /// the real run is about to get.
        private static func readHelp(
            resolvedBin: String, claudeBin: String, environment: [String: String],
        ) async -> String? {
            guard let directory = try? makeWorkingDirectory() else { return nil }
            defer { try? FileManager.default.removeItem(at: directory) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedBin)
            process.arguments = (resolvedBin == "/usr/bin/env" ? [claudeBin] : []) + ["--help"]
            process.environment = environment
            process.currentDirectoryURL = directory
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(helpProbeTimeoutSeconds))
                process.terminate()
            }
            defer { watchdog.cancel() }
            let handle = stdout.fileHandleForReading
            let data = await Task.detached { handle.readDataToEndOfFile() }.value
            return String(bytes: data, encoding: .utf8)
        }

        /// The folder the CLI keeps for a run started in `workingDirectory`:
        /// `<config dir>/projects/<name>`, where the config dir is
        /// `CLAUDE_CONFIG_DIR` or `~/.claude`, and the name is the directory's
        /// physical path with every character other than an ASCII letter or
        /// digit replaced by `-`. Nil when the path cannot be resolved.
        static func cliProjectFolder(workingDirectory: URL, environment: [String: String]) -> URL? {
            guard let resolved = realpath(workingDirectory.path, nil) else { return nil }
            defer { free(resolved) }
            let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
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
        static func removeIfOnlyEmptyFolders(_ folder: URL) {
            let fileManager = FileManager.default
            let own = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard own?.isDirectory == true, own?.isSymbolicLink != true else { return }
            guard let enumerator = fileManager.enumerator(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            ) else { return }
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { return }
            }
            try? fileManager.removeItem(at: folder)
        }
    }

#endif
