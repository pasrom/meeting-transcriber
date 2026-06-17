import Foundation

/// Wire shape for `GET /v1/jobs/<id>/naming` — the speaker-naming choice awaiting
/// resolution for a job: per-speaker auto-name suggestion + speaking time, plus
/// meeting participants. Excludes embeddings (large + PII) and audio/segments.
struct NamingStatusDTO: Codable, Equatable {
    struct Speaker: Codable, Equatable {
        let label: String
        let suggested: String
        let speakingSeconds: Double
    }

    let jobID: String
    let meetingTitle: String
    let speakers: [Speaker]
    let participants: [String]
}
