import Foundation

enum JobState: String, Codable, Sendable {
    case waiting
    case transcribing
    case diarizing
    case generatingProtocol
    case done
    case error
}

struct PipelineJob: Identifiable, Codable, Sendable {
    let id: UUID
    let meetingTitle: String
    let appName: String
    let mixPath: URL
    let appPath: URL?
    let micPath: URL?
    let micDelay: TimeInterval
    let enqueuedAt: Date
    var state: JobState
    var error: String?
    var protocolPath: URL?

    init(
        meetingTitle: String,
        appName: String,
        mixPath: URL,
        appPath: URL?,
        micPath: URL?,
        micDelay: TimeInterval
    ) {
        self.id = UUID()
        self.meetingTitle = meetingTitle
        self.appName = appName
        self.mixPath = mixPath
        self.appPath = appPath
        self.micPath = micPath
        self.micDelay = micDelay
        self.enqueuedAt = Date()
        self.state = .waiting
        self.error = nil
        self.protocolPath = nil
    }
}
