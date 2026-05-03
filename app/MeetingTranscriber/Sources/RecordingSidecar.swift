import Foundation

/// Metadata sidecar written next to dual-source recordings when record-only
/// mode is enabled. Consumed by an external transcription/diarization
/// pipeline (e.g. on a Linux GPU host) so it doesn't have to re-detect
/// context the macOS client already knows.
struct RecordingSidecar: Codable {
    /// Filename suffix appended to the recording basename to form the sidecar
    /// filename (e.g. `20260503_120000` → `20260503_120000_meta.json`).
    static let filenameSuffix = "_meta.json"

    /// Schema version stamped into every new sidecar. Bump when fields are
    /// added/removed/repurposed so downstream consumers can branch on it.
    static let currentVersion = 1

    let version: Int
    let title: String
    let appName: String
    let startedAt: Date
    let stoppedAt: Date
    let participants: [String]
    let micDelaySeconds: TimeInterval
    let files: Files

    struct Files: Codable {
        let mix: String
        let app: String?
        let mic: String?
    }

    init(
        title: String,
        appName: String,
        startedAt: Date,
        stoppedAt: Date,
        participants: [String],
        micDelaySeconds: TimeInterval,
        mixFilename: String,
        appFilename: String?,
        micFilename: String?,
    ) {
        self.version = Self.currentVersion
        self.title = title
        self.appName = appName
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.participants = participants
        self.micDelaySeconds = micDelaySeconds
        self.files = Files(mix: mixFilename, app: appFilename, mic: micFilename)
    }

    /// Writes the sidecar as `<basename>\(filenameSuffix)` into `directory`.
    /// Returns the resulting URL.
    @discardableResult
    func write(toDirectory directory: URL, basename: String) throws -> URL {
        let url = directory.appendingPathComponent("\(basename)\(Self.filenameSuffix)")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        return url
    }
}
