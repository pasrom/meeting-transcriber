import Foundation
import os.log

/// Centralized path constants and logger subsystem for the app.
enum AppPaths {
    /// Logger subsystem for all os.log loggers.
    static let logSubsystem = "com.meetingtranscriber"

    /// App data directory: `~/Library/Application Support/MeetingTranscriber/`
    /// In sandbox, this automatically resolves to the container path.
    static let dataDir: URL = {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            fatalError("Application Support directory unavailable")
        }
        return appSupport.appendingPathComponent("MeetingTranscriber")
    }()

    /// IPC directory: under `dataDir` for sandbox compatibility.
    static let ipcDir = dataDir.appendingPathComponent("ipc")

    /// Recordings directory.
    static let recordingsDir = dataDir.appendingPathComponent("recordings")

    /// Protocols output directory (legacy, inside Application Support).
    static let protocolsDir = dataDir.appendingPathComponent("protocols")

    /// Default protocols output in Downloads: `~/Downloads/MeetingTranscriber/`
    /// In sandbox, `FileManager.urls(for: .downloadsDirectory)` resolves to the container-granted path.
    static let downloadsProtocolsDir: URL = {
        guard let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
        else {
            return protocolsDir
        }
        return downloads.appendingPathComponent("MeetingTranscriber")
    }()

    /// Speaker voice profiles DB.
    static let speakersDB = dataDir.appendingPathComponent("speakers.json")

    /// Custom protocol prompt file.
    static let customPromptFile = dataDir.appendingPathComponent("protocol_prompt.md")

    /// Legacy IPC directory (`~/.meeting-transcriber/`) used before sandbox migration.
    private static let legacyIpcDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".meeting-transcriber")

    private static let logger = Logger(subsystem: logSubsystem, category: "AppPaths")

    /// Migrate IPC files from `~/.meeting-transcriber/` to `dataDir/ipc/`.
    /// Safe to call multiple times — copyItem fails gracefully if destination exists.
    static func migrateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyIpcDir.path) else { return }

        let filesToMigrate = [
            "processed_recordings.json",
            "pipeline_queue.json",
            "pipeline_log.jsonl",
        ]

        try? fm.createDirectory(at: ipcDir, withIntermediateDirectories: true)

        for name in filesToMigrate {
            let src = legacyIpcDir.appendingPathComponent(name)
            let dst = ipcDir.appendingPathComponent(name)
            do {
                try fm.copyItem(at: src, to: dst)
                logger.info("Migrated \(name) from legacy IPC directory")
            } catch CocoaError.fileWriteFileExists {
                // Already migrated — expected on subsequent launches
            } catch CocoaError.fileReadNoSuchFile {
                // Source doesn't exist — skip
            } catch {
                logger.error("Failed to migrate \(name): \(error.localizedDescription)")
            }
        }
    }
}
