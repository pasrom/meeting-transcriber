import Foundation

/// A job's status plus its result paths, for either a live (in-flight) job or a
/// finished job already reaped from the queue. Served by `GET /v1/jobs/<id>` and
/// persisted in `TerminalJobStore` (the wire shape and the stored shape are the
/// same; if they ever need to diverge, split then).
struct JobStatusDTO: Codable, Equatable {
    let jobID: String
    let state: JobState
    let meetingTitle: String
    let transcriptPath: String?
    let protocolPath: String?
    let error: String?
    let warnings: [String]
}

extension JobStatusDTO {
    /// Map a live pipeline job to its status shape (URL paths flattened to
    /// strings). Single source of the job→status mapping, shared by the live
    /// `GET /v1/jobs/<id>` lookup and the terminal-record persistence.
    init(job: PipelineJob) {
        self.init(
            jobID: job.id.uuidString,
            state: job.state,
            meetingTitle: job.meetingTitle,
            transcriptPath: job.transcriptPath?.path,
            protocolPath: job.protocolPath?.path,
            error: job.error,
            warnings: job.warnings,
        )
    }
}
