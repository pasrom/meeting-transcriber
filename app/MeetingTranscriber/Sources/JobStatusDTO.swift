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

/// The echo verdict in machine-readable form, and what was done about it. The
/// warning string is for a human reading the menu bar; a driver asserting on a
/// sentence would break on a reworded one, and could not tell "not analysed"
/// from "analysed, nothing found".
///
/// The two remedy outcomes live here with the verdict rather than in a shape of
/// their own, because both are gated on it: a nil `echo` means the answer
/// belongs to no measurement, which is the same reason neither is recorded
/// without one.
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

    /// Whether the far end was taken out of the microphone audio, or nil when
    /// the cancellation stage was never reached on this recording.
    ///
    /// Three states and not a `Bool`, for the reason this whole shape exists:
    /// nothing else a caller can see distinguishes them. A cancelled recording
    /// and one that never had an echo both end up with the far end written
    /// once, and `suppressedSegments` reads 0 for a run that cancelled, a run
    /// with the dedup switched off, and a run that did nothing at all.
    ///
    /// Absent is load-bearing rather than a decoding convenience. False is the
    /// whole of "the feature was on for this recording and the far end is still
    /// in the microphone track", which is the number that decides whether this
    /// can ever default to on; collapsing it into "not attempted" would hide
    /// exactly the population being counted.
    ///
    /// False deliberately does not say WHY, and it covers four different whys:
    /// no model could be resolved, the run threw, the self-check would not
    /// confirm it, or the confirmed output could not be moved into place. An
    /// earlier version of this comment named only the self-check, which was
    /// wrong in a way worth recording: on the last of those four the self-check
    /// had confirmed the run, so the sentence said the opposite of what
    /// happened. The job's `warnings` name which one, in prose, because that is
    /// where a human reads it; the field stays the count.
    ///
    /// An optional `Bool` rather than the named three-case type the waived rule
    /// asks for. Two reasons it loses here. This object is persisted and read
    /// leniently, and a raw-value enum throws on a case an older build does not
    /// know, which in this file costs the reader their whole job history; a
    /// `Bool` cannot grow a third value. And the outer `echo` already spells
    /// "not measured" as absence, so a second absence inside it reads the same
    /// way instead of introducing a second idiom for the same idea.
    var removed: Bool? // swiftlint:disable:this discouraged_optional_boolean

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
        removed = try container.decodeIfPresent(Bool.self, forKey: .removed)
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
