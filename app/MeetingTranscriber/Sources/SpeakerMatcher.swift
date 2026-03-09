import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

struct StoredSpeaker: Codable {
    let name: String
    let embedding: [Float]
}

class SpeakerMatcher {
    private let dbPath: URL
    private let threshold: Float

    init(dbPath: URL? = nil, threshold: Float = 0.65) {
        self.dbPath = dbPath ?? AppPaths.speakersDB
        self.threshold = threshold
        Self.migrateIfNeeded(dbPath: self.dbPath)
    }

    /// Reset old pyannote-format speakers.json (incompatible embeddings).
    /// Old format: `{ "name": [[float]] }` dict.
    /// New format: `[{ "name": str, "embedding": [float] }]` array.
    static func migrateIfNeeded(dbPath: URL) {
        guard let data = try? Data(contentsOf: dbPath),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }

        // Old format is a dictionary, new format is an array
        if json is [String: Any] {
            let backup = dbPath.deletingLastPathComponent()
                .appendingPathComponent("speakers.json.bak")
            try? FileManager.default.moveItem(at: dbPath, to: backup)
        }
    }

    /// Match diarization embeddings against stored speakers.
    func match(embeddings: [String: [Float]]) -> [String: String] {
        let stored = loadDB()
        var mapping: [String: String] = [:]
        var usedNames: Set<String> = []

        let sorted = embeddings.sorted { $0.key < $1.key }

        for (label, embedding) in sorted {
            var bestName: String?
            var bestDistance: Float = Float.greatestFiniteMagnitude

            for speaker in stored where !usedNames.contains(speaker.name) {
                let dist = Self.cosineDistance(embedding, speaker.embedding)
                if dist < bestDistance && dist < threshold {
                    bestDistance = dist
                    bestName = speaker.name
                }
            }

            if let name = bestName {
                mapping[label] = name
                usedNames.insert(name)
            } else {
                mapping[label] = label
            }
        }

        return mapping
    }

    /// Update speaker DB with confirmed names and their embeddings.
    func updateDB(mapping: [String: String], embeddings: [String: [Float]]) {
        var stored = loadDB()

        for (label, name) in mapping {
            guard name != label, let embedding = embeddings[label] else { continue }

            if let idx = stored.firstIndex(where: { $0.name == name }) {
                stored[idx] = StoredSpeaker(name: name, embedding: embedding)
            } else {
                stored.append(StoredSpeaker(name: name, embedding: embedding))
            }
        }

        saveDB(stored)
    }

    func loadDB() -> [StoredSpeaker] {
        guard let data = try? Data(contentsOf: dbPath) else { return [] }
        return (try? JSONDecoder().decode([StoredSpeaker].self, from: data)) ?? []
    }

    func saveDB(_ speakers: [StoredSpeaker]) {
        do {
            let data = try JSONEncoder().encode(speakers)
            let tmp = dbPath.deletingLastPathComponent()
                .appendingPathComponent("speakers.json.tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(dbPath, withItemAt: tmp)
        } catch {
            logger.error("Failed to save speaker DB: \(error)")
        }
    }

    /// Cosine distance: 0 = identical, 2 = opposite.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 2 }
        return 1 - dot / denom
    }
}
