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
    let mixPath: URL?
    let appPath: URL?
    let micPath: URL?
    let micDelay: TimeInterval
    let participants: [String]
    let enqueuedAt: Date
    /// Wall-clock time the recording started (meeting start), captured directly
    /// by the recorder at start (`RecordingResult.recordingStartDate`), not
    /// derived from `systemUptime` (which freezes during sleep). Used to anchor
    /// the output-file basename so the filename reflects when the meeting happened,
    /// not when the pipeline processed it. `nil` for reimport/orphan-recovery
    /// jobs (no live recording) and for legacy snapshots persisted before this
    /// field existed — callers fall back to `enqueuedAt`.
    var meetingStartTime: Date?
    var state: JobState
    var error: String?
    var warnings: [String]
    var transcriptPath: URL?
    var protocolPath: URL?
    var namingSlug: String?
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
        self.transcriptPath = nil
        self.protocolPath = nil
        self.namingSlug = nil
        self.usedDiarizerMode = nil
        self.autoSkipNaming = autoSkipNaming
    }
}
