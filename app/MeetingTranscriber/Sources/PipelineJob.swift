import Foundation

enum JobState: String, Codable {
    case waiting
    case transcribing
    case diarizing
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case generatingProtocol
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case speakerNamingPending
    case done
    case error

    /// A finished state the pipeline won't move out of on its own.
    var isTerminal: Bool {
        self == .done || self == .error
    }

    /// Human-readable label for this job state.
    var label: String {
        switch self {
        case .waiting: "Waiting..."
        case .transcribing: "Transcribing..."
        case .diarizing: "Diarizing..."
        case .generatingProtocol: "Generating Protocol..."
        case .speakerNamingPending: "Name Speakers..."
        case .done: "Done"
        case .error: "Error"
        }
    }
}

/// Where a job's audio sits once stage 3 has handed it to the output folder:
/// the destination for a slot that was actually moved, the original source for
/// every other outcome, including a move that failed. Reporting the intent
/// instead would put a path on the job that nothing can open, and the
/// processed-recordings ledger would record it while the real file waited in
/// staging to be re-picked as an orphan.
struct RelocatedAudioPaths {
    let mix: URL?
    let app: URL?
    let mic: URL?
}

struct PipelineJob: Identifiable, Codable {
    let id: UUID

    /// Short 8-hex-char form of `id`, used as a `[xxxxxxxx]` log prefix to
    /// correlate diagnostic lines across the transcribe → diarize → protocol
    /// stages of the same job.
    var shortID: String {
        Self.shortID(for: id)
    }

    /// Same format, callable when only the UUID is in scope.
    static func shortID(for id: UUID) -> String {
        String(id.uuidString.prefix(8).lowercased())
    }

    let meetingTitle: String
    let appName: String
    /// nil when the job is a paired-import without a `_mix.wav` source — the
    /// pipeline mixes `appPath`+`micPath` directly to the workdir `mix_16k.wav`
    /// in that case, so no persistent mix file is written.
    ///
    /// Settable only from inside this file, so `recordRelocatedAudio` below
    /// stays the single writer after enqueue. Any other reassignment silently
    /// changes what the processed-recordings ledger records and what the
    /// snapshot restore judges the job by, and both failures are invisible.
    private(set) var mixPath: URL?
    private(set) var appPath: URL?
    private(set) var micPath: URL?
    let micDelay: TimeInterval
    let participants: [String]
    let enqueuedAt: Date
    /// Wall-clock time the recording started (meeting start), captured directly
    /// by the recorder at start (`RecordingResult.recordingStartDate`), not
    /// derived from `systemUptime` (which freezes during sleep). Used to anchor
    /// the output-file basename so the filename reflects when the meeting happened,
    /// not when the pipeline processed it. `nil` for reimport/orphan-recovery
    /// jobs (no live recording) and for legacy snapshots persisted before this
    /// field existed. Output artifact names fall back to `enqueuedAt`, but
    /// protocol prompts must preserve `nil` so they never treat processing time
    /// as authoritative meeting context.
    var meetingStartTime: Date?

    /// Timestamp used only for output artifact names. Reimports and recovery
    /// have no real meeting start, so their filenames use enqueue time.
    /// Record where stage 3 left this job's audio.
    ///
    /// Until this existed, a relocated job kept naming the staging path the
    /// move had just emptied, so the snapshot restore discarded it although the
    /// audio was sitting in the output folder, and the ledger recorded a path
    /// that no longer existed.
    mutating func recordRelocatedAudio(_ paths: RelocatedAudioPaths) {
        mixPath = paths.mix
        appPath = paths.app
        micPath = paths.mic
    }

    var artifactStartTime: Date {
        meetingStartTime ?? enqueuedAt
    }

    var state: JobState
    var error: String?
    var warnings: [String]
    /// The echo detector's verdict, once the transcription stage has run it.
    /// Nil for single-source jobs and whenever no verdict was possible.
    var echo: EchoDetectionDTO?
    var transcriptPath: URL?
    var protocolPath: URL?
    var namingSlug: String?
    // Output policy captured when this job enters the queue. Optional so
    // snapshots saved before transcript-output options existed still decode.
    // Nil falls back to the queue's legacy-compatible defaults.
    // swiftlint:disable:next discouraged_optional_boolean
    var includeFullTranscriptInProtocol: Bool?
    // See `includeFullTranscriptInProtocol`.
    // swiftlint:disable:next discouraged_optional_boolean
    var saveRawTranscriptSeparately: Bool?
    /// Diarizer mode that produced the *current* `speakerNamingDataByJob`
    /// entry. Set by `PipelineQueue` after diarisation completes (in the
    /// initial pipeline run and after `lateDiarization`). Used by the
    /// re-run UI in `SpeakerNamingView` to initialise the mode picker to
    /// the mode that was actually used, not the current global setting
    /// (which the user may have changed after recording).
    /// `nil` for legacy jobs persisted before this field existed —
    /// callers fall back to the current global setting.
    var usedDiarizerMode: DiarizerMode?

    // When true, the pipeline accepts the auto-assigned speaker names instead of
    // parking at .speakerNamingPending for an interactive client. Set by the
    // headless blocking-transcribe API path so a multi-speaker job still
    // completes on its own.
    //
    // Optional (not Bool) so a legacy snapshot missing this key decodes as nil:
    // synthesized Codable throws on a missing non-optional key. nil and false
    // both mean "keep the interactive pause", so callers read `== true`.
    // swiftlint:disable:next discouraged_optional_boolean
    var autoSkipNaming: Bool?

    /// The output directory this job's naming sidecars were written under,
    /// captured when they were written.
    ///
    /// A queue's `outputDir` is the *current* setting. Repointing the output
    /// folder would otherwise make the snapshot restore clean up the new folder
    /// while the files sit in the old one, and the job that names them is
    /// discarded in the same breath, so nothing could ever find them again.
    ///
    /// `nil` for legacy snapshots and for jobs that never wrote sidecars;
    /// callers fall back to the current output directory, which is what the
    /// code did before this field existed.
    var sidecarOutputDir: URL?

    init(
        meetingTitle: String,
        appName: String,
        mixPath: URL?,
        appPath: URL?,
        micPath: URL?,
        micDelay: TimeInterval,
        participants: [String] = [],
        meetingStartTime: Date? = nil,
        autoSkipNaming: Bool = false,
        // swiftlint:disable:next discouraged_optional_boolean
        includeFullTranscriptInProtocol: Bool? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        saveRawTranscriptSeparately: Bool? = nil,
    ) {
        self.id = UUID()
        self.meetingTitle = meetingTitle
        self.appName = appName
        self.mixPath = mixPath
        self.appPath = appPath
        self.micPath = micPath
        self.micDelay = micDelay
        self.participants = participants
        self.enqueuedAt = Date()
        self.meetingStartTime = meetingStartTime
        self.state = .waiting
        self.error = nil
        self.warnings = []
        self.echo = nil
        self.transcriptPath = nil
        self.protocolPath = nil
        self.namingSlug = nil
        self.includeFullTranscriptInProtocol = includeFullTranscriptInProtocol
        self.saveRawTranscriptSeparately = saveRawTranscriptSeparately
        self.usedDiarizerMode = nil
        self.autoSkipNaming = autoSkipNaming
    }
}
