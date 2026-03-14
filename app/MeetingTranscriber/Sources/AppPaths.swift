import Foundation
import os.log

/// Centralized path constants and logger subsystem for the app.
enum AppPaths {
    /// Logger subsystem for all os.log loggers.
    static let logSubsystem = "com.meetingtranscriber"

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// IPC directory: `~/.meeting-transcriber/`
    static let ipcDir = home.appendingPathComponent(".meeting-transcriber")

    /// App data directory: `~/Library/Application Support/MeetingTranscriber/`
    static let dataDir = home.appendingPathComponent("Library/Application Support/MeetingTranscriber")

    /// Recordings directory.
    static let recordingsDir = dataDir.appendingPathComponent("recordings")

    /// Protocols output directory.
    static let protocolsDir = dataDir.appendingPathComponent("protocols")

    /// Speaker voice profiles DB.
    static let speakersDB = dataDir.appendingPathComponent("speakers.json")

    /// Custom protocol prompt file.
    static let customPromptFile = dataDir.appendingPathComponent("protocol_prompt.md")
}
