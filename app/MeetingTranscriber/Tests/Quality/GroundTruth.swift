import Foundation

/// Decoded shape of a `<fixture>_truth.json` file produced by
/// `scripts/generate_quality_fixtures.sh`. Used as the reference side of
/// WER/DER computations.
struct GroundTruth: Decodable {
    let fixture: String
    let audio: String
    let duration: Double
    let sampleRate: Int
    let text: String
    let turns: [Turn]

    struct Turn: Decodable {
        let speaker: String
        let start: Double
        let end: Double
        let text: String
    }

    /// Convert the ground-truth turns to the diarization-side turn shape.
    var diarizationTurns: [DERCalculator.Turn] {
        turns.map { .init(speaker: $0.speaker, start: $0.start, end: $0.end) }
    }

    static func load(named name: String) throws -> Self {
        let url = qualityFixturesDir
            .appendingPathComponent("\(name)_truth.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Absolute URL to the audio file referenced by this ground truth.
    var audioURL: URL {
        Self.qualityFixturesDir.appendingPathComponent(audio)
    }

    static var qualityFixturesDir: URL {
        // #filePath → absolute path to .../Tests/Quality/GroundTruth.swift
        // Fixtures live at .../Tests/Fixtures/quality/.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Quality/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("quality")
    }
}
