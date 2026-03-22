import Foundation

enum JobState: String, Codable, Sendable {
    case waiting
    case transcribing
    case diarizing
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case generatingProtocol
    case done
    case error

    /// Human-readable label for this job state.
    var label: String {
        switch self {
        case .waiting: "Waiting..."
        case .transcribing: "Transcribing..."
        case .diarizing: "Diarizing..."
        case .generatingProtocol: "Generating Protocol..."
        case .done: "Done"
        case .error: "Error"
        }
    }
}

struct PipelineJob: Identifiable, Codable, Sendable {
    let id: UUID
    let meetingTitle: String
    let appName: String
    let mixPath: URL
    let appPath: URL?
    let micPath: URL?
    let micDelay: TimeInterval
    let participants: [String]
    let enqueuedAt: Date
    var state: JobState
    var error: String?
    var warnings: [String]
    var transcriptPath: URL?
    var protocolPath: URL?

    init(
        meetingTitle: String,
        appName: String,
        mixPath: URL,
        appPath: URL?,
        micPath: URL?,
        micDelay: TimeInterval,
        participants: [String] = [],
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
        self.state = .waiting
        self.error = nil
        self.warnings = []
        self.transcriptPath = nil
        self.protocolPath = nil
    }
}
