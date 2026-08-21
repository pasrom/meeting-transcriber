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
    /// Absent when the job was not dual-source, or when no honest verdict was
    /// possible (a silent track, or less than one analysis window).
    let echo: EchoDetectionDTO?

    /// Spelled out rather than left to the memberwise init so `echo` can default
    /// to nil: it is an addition to an existing wire shape, and every caller
    /// that predates it means exactly "no verdict".
    init(
        jobID: String,
        state: JobState,
        meetingTitle: String,
        transcriptPath: String?,
        protocolPath: String?,
        error: String?,
        warnings: [String],
        echo: EchoDetectionDTO? = nil,
    ) {
        self.jobID = jobID
        self.state = state
        self.meetingTitle = meetingTitle
        self.transcriptPath = transcriptPath
        self.protocolPath = protocolPath
        self.error = error
        self.warnings = warnings
        self.echo = echo
    }
}

/// The echo detector's verdict in machine-readable form. The warning string is
/// for a human reading the menu bar; a driver asserting on a sentence would
/// break on a reworded one, and could not tell "not analysed" from "analysed,
/// nothing found".
struct EchoDetectionDTO: Codable, Equatable {
    /// Whether the verdict cleared every floor, i.e. whether the warning fired.
    let detected: Bool
    /// Share of analysed windows carrying the same audio on both tracks, 0...1.
    let affectedWindowShare: Double
    let windowsScored: Int
    let windowsAffected: Int
    /// How many microphone segments were left out of the transcript as the
    /// loudspeaker coming back. Reported because the app is removing content a
    /// caller might otherwise go looking for, and because it is the only
    /// machine-readable evidence that the dedup did anything: a transcript that
    /// simply never had duplicates looks the same from outside.
    var suppressedSegments: Int = 0

    /// The detector's own result, narrowed to what belongs on a wire and in a
    /// persisted job. The per-window series stays behind: it grows with the
    /// recording, and a caller polling a job does not want it.
    init(_ result: EchoBleedDetector.Result) {
        detected = result.isAffected
        affectedWindowShare = result.affectedWindowShare
        windowsScored = result.windowsScored
        windowsAffected = result.windowsAffected
    }

    /// Spelled out because a synthesized decoder demands every key. This shape
    /// is persisted in the pipeline snapshot and in finished-job records, so a
    /// throwing decode on a field added later would discard a user's whole job
    /// history at the next launch.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detected = try container.decode(Bool.self, forKey: .detected)
        affectedWindowShare = try container.decode(Double.self, forKey: .affectedWindowShare)
        windowsScored = try container.decode(Int.self, forKey: .windowsScored)
        windowsAffected = try container.decode(Int.self, forKey: .windowsAffected)
        suppressedSegments = try container.decodeIfPresent(Int.self, forKey: .suppressedSegments) ?? 0
    }
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
            echo: job.echo,
        )
    }
}
