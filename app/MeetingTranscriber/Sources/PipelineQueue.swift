import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "PipelineQueue")

@MainActor
@Observable
class PipelineQueue {
    private(set) var jobs: [PipelineJob] = []
    private let logDir: URL

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

    init(logDir: URL? = nil) {
        self.logDir = logDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
    }

    var activeJobs: [PipelineJob] {
        jobs.filter { [.transcribing, .diarizing, .generatingProtocol].contains($0.state) }
    }

    var pendingJobs: [PipelineJob] {
        jobs.filter { $0.state == .waiting }
    }

    var completedJobs: [PipelineJob] {
        jobs.filter { $0.state == .done }
    }

    var errorJobs: [PipelineJob] {
        jobs.filter { $0.state == .error }
    }

    func enqueue(_ job: PipelineJob) {
        jobs.append(job)
        appendLog(jobID: job.id, event: "enqueued", from: nil, to: job.state)
        writeSnapshot()
        logger.info("Enqueued job: \(job.meetingTitle) (\(job.id))")
    }

    func removeJob(id: UUID) {
        jobs.removeAll { $0.id == id }
        writeSnapshot()
    }

    func updateJobState(id: UUID, to newState: JobState, error: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let oldState = jobs[index].state
        jobs[index].state = newState
        if let error { jobs[index].error = error }
        appendLog(jobID: id, event: "state_change", from: oldState, to: newState)
        writeSnapshot()
        onJobStateChange?(jobs[index], oldState, newState)
    }

    // MARK: - JSON Logging

    private func writeSnapshot() {
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(jobs)
            let tmpPath = logDir.appendingPathComponent("pipeline_queue.tmp")
            try data.write(to: tmpPath)
            let snapshotPath = logDir.appendingPathComponent("pipeline_queue.json")
            _ = try FileManager.default.replaceItemAt(snapshotPath, withItemAt: tmpPath)
        } catch {
            logger.error("Failed to write queue snapshot: \(error)")
        }
    }

    private func appendLog(jobID: UUID, event: String, from: JobState?, to: JobState) {
        let entry: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "job_id": jobID.uuidString,
            "event": event,
            "from": from?.rawValue ?? "-",
            "to": to.rawValue,
        ]
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            let logPath = logDir.appendingPathComponent("pipeline_log.jsonl")
            let line = String(data: data, encoding: .utf8)! + "\n"
            if FileManager.default.fileExists(atPath: logPath.path) {
                let handle = try FileHandle(forWritingTo: logPath)
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try line.write(to: logPath, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to append pipeline log: \(error)")
        }
    }
}
