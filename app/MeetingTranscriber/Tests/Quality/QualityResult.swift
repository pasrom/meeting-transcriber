import Foundation

/// Single engine-vs-fixture data point. Multiple of these are aggregated into
/// `quality-results.json` and uploaded as a CI artifact for diffing against
/// the main-branch baseline.
struct QualityResult: Codable {
    let engine: String
    let fixture: String
    let modelVariant: String?
    let wer: Double?
    let der: Double?
    let werBreakdown: WERBreakdown?
    let derBreakdown: DERBreakdown?
    let appVersion: String
    let timestamp: String
    let durationSeconds: Double

    struct WERBreakdown: Codable {
        let substitutions: Int
        let deletions: Int
        let insertions: Int
        let referenceLength: Int
    }

    struct DERBreakdown: Codable {
        let missedSpeech: Double
        let falseAlarm: Double
        let speakerConfusion: Double
        let totalReference: Double
    }
}

/// Append-only writer used by quality-suite tests. Each test contributes one
/// or more `QualityResult` rows; the runner collects them in-process and
/// flushes to disk in a single shared destination so CI can pick up the file
/// as an artifact regardless of which test ran.
@MainActor
final class QualityResultsWriter {
    static let shared = QualityResultsWriter()
    private var rows: [QualityResult] = []

    private init() {}

    func append(_ row: QualityResult) {
        rows.append(row)
    }

    /// Write all collected rows to the destination file. Idempotent — calling
    /// twice produces the same content unless `append` was called between.
    /// CI sets `QUALITY_RESULTS_PATH` to the artifact path; locally the file
    /// lands next to the package in `.build/quality-results.json`.
    func flush() throws -> URL {
        let url = destinationURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rows)
        try data.write(to: url, options: .atomic)
        return url
    }

    func reset() {
        rows.removeAll()
    }

    var collectedRows: [QualityResult] {
        rows
    }

    private var destinationURL: URL {
        if let override = ProcessInfo.processInfo.environment["QUALITY_RESULTS_PATH"] {
            return URL(fileURLWithPath: override)
        }
        // Default: `<repo>/app/MeetingTranscriber/.build/quality-results.json`.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Quality/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // MeetingTranscriber package root
            .appendingPathComponent(".build")
            .appendingPathComponent("quality-results.json")
    }
}

extension QualityResult.WERBreakdown {
    init(_ b: WERCalculator.Breakdown) {
        self.init(
            substitutions: b.substitutions,
            deletions: b.deletions,
            insertions: b.insertions,
            referenceLength: b.referenceLength,
        )
    }
}

extension QualityResult.DERBreakdown {
    init(_ b: DERCalculator.Breakdown) {
        self.init(
            missedSpeech: b.missedSpeech,
            falseAlarm: b.falseAlarm,
            speakerConfusion: b.speakerConfusion,
            totalReference: b.totalReference,
        )
    }
}
