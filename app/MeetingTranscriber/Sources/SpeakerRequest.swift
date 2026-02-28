import Foundation

/// IPC model: Python writes this after diarization so the app can show a naming UI.
struct SpeakerRequest: Codable {
    let version: Int
    let timestamp: String
    let meetingTitle: String
    let audioSamplesDir: String
    let speakers: [SpeakerInfo]

    enum CodingKeys: String, CodingKey {
        case version, timestamp, speakers
        case meetingTitle = "meeting_title"
        case audioSamplesDir = "audio_samples_dir"
    }
}

struct SpeakerInfo: Codable, Identifiable {
    let label: String
    let autoName: String?
    let confidence: Double
    let speakingTimeSeconds: Double
    let sampleFile: String

    var id: String { label }

    enum CodingKeys: String, CodingKey {
        case label, confidence
        case autoName = "auto_name"
        case speakingTimeSeconds = "speaking_time_seconds"
        case sampleFile = "sample_file"
    }
}

/// IPC model: the app writes this after the user confirms speaker names.
struct SpeakerResponse: Codable {
    let version: Int
    let speakers: [String: String]
}
