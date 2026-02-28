import Foundation

/// Matches the JSON status file written by the Python status emitter.
struct TranscriberStatus: Codable {
    let version: Int
    let timestamp: String
    let state: TranscriberState
    let detail: String
    let meeting: MeetingInfo?
    let protocolPath: String?
    let error: String?
    let pid: Int?

    enum CodingKeys: String, CodingKey {
        case version, timestamp, state, detail, meeting, error, pid
        case protocolPath = "protocol_path"
    }
}

enum TranscriberState: String, Codable {
    case idle
    case watching
    case recording
    case transcribing
    case generatingProtocol = "generating_protocol"
    case waitingForSpeakerNames = "waiting_for_speaker_names"
    case protocolReady = "protocol_ready"
    case error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .watching: "Watching for Meetings..."
        case .recording: "Recording"
        case .transcribing: "Transcribing..."
        case .generatingProtocol: "Generating Protocol..."
        case .waitingForSpeakerNames: "Name Speakers"
        case .protocolReady: "Protocol Ready"
        case .error: "Error"
        }
    }

    var icon: String {
        switch self {
        case .idle: "waveform.circle"
        case .watching: "eye.fill"
        case .recording: "record.circle.fill"
        case .transcribing: "waveform"
        case .generatingProtocol: "waveform"
        case .waitingForSpeakerNames: "person.2.fill"
        case .protocolReady: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct MeetingInfo: Codable {
    let app: String
    let title: String
    let pid: Int
}
