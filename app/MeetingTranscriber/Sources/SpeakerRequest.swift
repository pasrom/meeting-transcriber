import Foundation

/// IPC model: Python writes this after diarization so the app can show a naming UI.
struct SpeakerRequest: Codable {
    let version: Int
    let timestamp: String
    let meetingTitle: String
    let audioSamplesDir: String
    let speakers: [SpeakerInfo]
    let expectedNames: [String]?

    enum CodingKeys: String, CodingKey {
        case version, timestamp, speakers
        case meetingTitle = "meeting_title"
        case audioSamplesDir = "audio_samples_dir"
        case expectedNames = "expected_names"
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

// MARK: - Speaker Count IPC

/// IPC model: Python writes this before diarization to ask how many speakers.
struct SpeakerCountRequest: Codable {
    let version: Int
    let timestamp: String
    let meetingTitle: String

    enum CodingKeys: String, CodingKey {
        case version, timestamp
        case meetingTitle = "meeting_title"
    }
}

/// IPC model: the app writes this after the user picks a speaker count.
struct SpeakerCountResponse: Codable {
    let version: Int
    let speakerCount: Int

    enum CodingKeys: String, CodingKey {
        case version
        case speakerCount = "speaker_count"
    }
}
