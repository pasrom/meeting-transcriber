import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

struct StoredSpeaker: Codable {
    let name: String
    let embeddings: [[Float]]

    // Migrate old single-embedding format automatically
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let multi = try? container.decode([[Float]].self, forKey: .embeddings) {
            embeddings = multi
        } else if let single = try? container.decode([Float].self, forKey: .embedding) {
            embeddings = [single]
        } else {
            embeddings = []
        }
    }

    init(name: String, embeddings: [[Float]]) {
        self.name = name
        self.embeddings = embeddings
    }

    private enum CodingKeys: String, CodingKey {
        case name, embeddings, embedding
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(embeddings, forKey: .embeddings)
    }
}

class SpeakerMatcher {
    private let dbPath: URL
    private let threshold: Float
    private let confidenceMargin: Float
    private static let maxEmbeddingsPerSpeaker = 5

    init(dbPath: URL? = nil, threshold: Float = 0.40, confidenceMargin: Float = 0.10) {
        self.dbPath = dbPath ?? AppPaths.speakersDB
        self.threshold = threshold
        self.confidenceMargin = confidenceMargin
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
    /// Uses min-distance across all stored embeddings per speaker,
    /// with confidence margin to reject ambiguous matches.
    func match(embeddings: [String: [Float]]) -> [String: String] {
        let stored = loadDB()
        var mapping: [String: String] = [:]
        var usedNames: Set<String> = []

        let sorted = embeddings.sorted { $0.key < $1.key }

        for (label, embedding) in sorted {
            var bestName: String?
            var bestDistance = Float.greatestFiniteMagnitude
            var secondBestDistance = Float.greatestFiniteMagnitude

            for speaker in stored where !usedNames.contains(speaker.name) {
                // Min distance across all stored embeddings for this speaker
                let dist = speaker.embeddings
                    .map { Self.cosineDistance(embedding, $0) }
                    .min() ?? Float.greatestFiniteMagnitude

                if dist < bestDistance {
                    secondBestDistance = bestDistance
                    bestDistance = dist
                    bestName = speaker.name
                } else if dist < secondBestDistance {
                    secondBestDistance = dist
                }
            }

            // Must be below threshold AND have sufficient margin over second-best
            if let name = bestName,
               bestDistance < threshold,
               secondBestDistance - bestDistance >= confidenceMargin {
                mapping[label] = name
                usedNames.insert(name)
            } else {
                mapping[label] = label
            }
        }

        return mapping
    }

    /// Update speaker DB with confirmed names and their embeddings.
    /// Appends new embedding to the speaker's list (FIFO, max 5).
    func updateDB(mapping: [String: String], embeddings: [String: [Float]]) {
        var stored = loadDB()

        for (label, name) in mapping {
            guard name != label, let embedding = embeddings[label] else { continue }

            if let idx = stored.firstIndex(where: { $0.name == name }) {
                var updated = stored[idx].embeddings
                updated.append(embedding)
                if updated.count > Self.maxEmbeddingsPerSpeaker {
                    updated.removeFirst(updated.count - Self.maxEmbeddingsPerSpeaker)
                }
                stored[idx] = StoredSpeaker(name: name, embeddings: updated)
            } else {
                stored.append(StoredSpeaker(name: name, embeddings: [embedding]))
            }
        }

        saveDB(stored)
    }

    func loadDB() -> [StoredSpeaker] {
        guard let data = try? Data(contentsOf: dbPath) else { return [] }
        return (try? JSONDecoder().decode([StoredSpeaker].self, from: data)) ?? []
    }

    /// Names of all stored speakers, sorted alphabetically. Used as suggestion
    /// chips in the speaker-naming UI ("Known voices" row) so the user can
    /// reuse names from previous meetings with one click.
    func allSpeakerNames() -> [String] {
        loadDB().map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    /// Pre-assign participant names to unmatched speakers by speaking time.
    /// When unmatched remote speaker count == unmatched participant count,
    /// assign by descending speaking time order.
    /// This is a heuristic — the naming popup lets users correct mistakes.
    ///
    /// - Parameters:
    ///   - mapping: Current label → name mapping (from `match()`)
    ///   - speakingTimes: Speaking time per label
    ///   - participants: Meeting participant names (e.g. from Teams)
    ///   - excludeLabels: Labels to exclude (e.g. mic speaker already identified)
    /// - Returns: Updated mapping with participants pre-assigned
    static func preMatchParticipants(
        mapping: [String: String],
        speakingTimes: [String: TimeInterval],
        participants: [String],
        excludeLabels: Set<String> = [],
    ) -> [String: String] {
        // Find unmatched labels: name equals raw label (not yet named) and not excluded
        let unmatchedLabels = mapping.keys.filter { label in
            mapping[label] == label && !excludeLabels.contains(label)
        }

        // Find unused participants: not already assigned as a value in mapping
        let usedNames = Set(mapping.values)
        let unusedParticipants = participants.filter { !usedNames.contains($0) }

        // Only assign when counts match exactly
        guard unmatchedLabels.count == unusedParticipants.count,
              !unmatchedLabels.isEmpty else {
            return mapping
        }

        // Sort unmatched labels by speaking time descending
        let sortedLabels = unmatchedLabels.sorted { a, b in
            (speakingTimes[a] ?? 0) > (speakingTimes[b] ?? 0)
        }

        var updated = mapping
        for (label, participant) in zip(sortedLabels, unusedParticipants) {
            updated[label] = participant
        }

        return updated
    }

    /// Cosine distance: 0 = identical, 2 = opposite.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0 ..< a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 2 }
        return 1 - dot / denom
    }
}
