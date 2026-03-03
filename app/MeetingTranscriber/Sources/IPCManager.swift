import Foundation

/// Handles file-based IPC with the Python transcriber process.
///
/// Methods return optionals / throw so callers decide logging policy.
/// The base directory is injectable for testing.
struct IPCManager {
    let baseDir: URL

    init(baseDir: URL? = nil) {
        self.baseDir = baseDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
    }

    // MARK: - Load

    func loadSpeakerRequest() -> SpeakerRequest? {
        let url = baseDir.appendingPathComponent("speaker_request.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeakerRequest.self, from: data)
    }

    func loadSpeakerCountRequest() -> SpeakerCountRequest? {
        let url = baseDir.appendingPathComponent("speaker_count_request.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeakerCountRequest.self, from: data)
    }

    // MARK: - Write

    func writeSpeakerResponse(_ mapping: [String: String]) throws {
        let response = SpeakerResponse(version: 1, speakers: mapping)
        let data = try JSONEncoder().encode(response)
        let url = baseDir.appendingPathComponent("speaker_response.json")
        try data.write(to: url, options: .atomic)
    }

    func writeSpeakerCountResponse(_ count: Int) throws {
        let response = SpeakerCountResponse(version: 1, speakerCount: count)
        let data = try JSONEncoder().encode(response)
        let url = baseDir.appendingPathComponent("speaker_count_response.json")
        try data.write(to: url, options: .atomic)
    }
}
