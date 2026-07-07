import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineEventLog")

/// Append-only JSONL log of `PipelineQueue` job state transitions, one JSON
/// object per line in `pipeline_log.jsonl` (in `logDir`).
///
/// Pure persistence with no back-references into queue state, so it needs no
/// delegate. Each entry is `timestamp`/`job_id`/`event`/`from`/`to`; the first
/// write creates the file and restricts it to owner-only (0600) so the meeting
/// log isn't world-readable, and subsequent writes append via a `FileHandle`
/// (inheriting those permissions). It self-ensures `logDir` before a write
/// (creating it only when absent) rather than sharing the queue's cached
/// `logDirCreated` flag.
struct PipelineEventLog {
    let logDir: URL

    /// Shared formatter — `ISO8601DateFormatter` init is non-trivial.
    /// `nonisolated(unsafe)`: thread-safe for read-only use since macOS 10.9
    /// despite not being formally `Sendable`.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    var path: URL {
        logDir.appendingPathComponent("pipeline_log.jsonl")
    }

    /// Append one entry describing a job state transition. `from == nil`
    /// serializes as `"-"` (enqueue and recovery have no prior state).
    func append(jobID: UUID, event: String, from: JobState?, to: JobState) {
        let entry: [String: String] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "job_id": jobID.uuidString,
            "event": event,
            "from": from?.rawValue ?? "-",
            "to": to.rawValue,
        ]
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(entry)
            let logPath = path
            // swiftlint:disable:next force_unwrapping
            let line = String(data: data, encoding: .utf8)! + "\n"
            if FileManager.default.fileExists(atPath: logPath.path) {
                let handle = try FileHandle(forWritingTo: logPath)
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                // swiftlint:disable:next force_unwrapping
                handle.write(line.data(using: .utf8)!)
            } else {
                try line.write(to: logPath, atomically: true, encoding: .utf8)
                // First write creates the file — restrict it to owner-only so
                // the meeting log isn't world-readable. Subsequent appends go
                // through the FileHandle branch and inherit these permissions.
                try FileManager.default.restrictToOwner(logPath)
            }
        } catch {
            logger.error("Failed to append pipeline log: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ensure `logDir` exists before a write. Skips the `createDirectory`
    /// syscall when the directory already exists (the steady-state case, since
    /// the queue creates its log dir early), so no cached flag is needed.
    private func ensureLogDir() {
        guard !FileManager.default.fileExists(atPath: logDir.path) else { return }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }
}
