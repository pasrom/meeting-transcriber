// swiftlint:disable discouraged_optional_collection
// Optional `[Float]?` is intentional throughout this file: nil signals
// "no centroid yet" (legacy entries / dim-mismatch / empty input), which is
// semantically distinct from an empty embedding vector.
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

struct StoredSpeaker: Codable {
    let name: String
    /// Recent quality samples (FIFO, max `SpeakerMatcher.maxRecentSamples`).
    /// Used as a fallback when the centroid match is borderline, and as the
    /// seed for `centroid` on first confirmation after the v3 schema upgrade.
    let embeddings: [[Float]]
    /// Running mean of all quality-filtered embeddings ever confirmed for this
    /// speaker. The primary match anchor in v3+. nil for legacy entries; the
    /// matcher computes `meanEmbedding(embeddings)` lazily until the next
    /// confirmation persists a real centroid.
    let centroid: [Float]?
    /// Number of embeddings folded into `centroid` so far. Drives the running-
    /// average update math and tells us whether we trust the centroid.
    let centroidSampleCount: Int
    /// Wall-clock time when this speaker was last confirmed by the user via
    /// `updateDB`. Used to rank suggestion chips by recency. nil for entries
    /// migrated from older DB versions that didn't track usage.
    let lastUsed: Date?
    /// Number of times this speaker has been confirmed by the user across
    /// recordings. Defaults to 0 for entries that pre-date usage tracking.
    let useCount: Int

    // Migrate old single-embedding format automatically (legacy `embedding`
    // key); default lastUsed/useCount for entries before recency tracking;
    // default centroid/centroidSampleCount for entries before v3 schema.
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
        centroid = try container.decodeIfPresent([Float].self, forKey: .centroid)
        centroidSampleCount = try container.decodeIfPresent(Int.self, forKey: .centroidSampleCount) ?? 0
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
    }

    init(
        name: String,
        embeddings: [[Float]],
        centroid: [Float]? = nil,
        centroidSampleCount: Int = 0,
        lastUsed: Date? = nil,
        useCount: Int = 0,
    ) {
        self.name = name
        self.embeddings = embeddings
        self.centroid = centroid
        self.centroidSampleCount = centroidSampleCount
        self.lastUsed = lastUsed
        self.useCount = useCount
    }

    private enum CodingKeys: String, CodingKey {
        case name, embeddings, embedding, centroid, centroidSampleCount, lastUsed, useCount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(embeddings, forKey: .embeddings)
        try container.encodeIfPresent(centroid, forKey: .centroid)
        if centroidSampleCount > 0 {
            try container.encode(centroidSampleCount, forKey: .centroidSampleCount)
        }
        try container.encodeIfPresent(lastUsed, forKey: .lastUsed)
        // Skip when 0 so entries that pre-date recency tracking round-trip
        // byte-identical (no spurious useCount=0 field added on first save).
        if useCount > 0 {
            try container.encode(useCount, forKey: .useCount)
        }
    }
}

class SpeakerMatcher {
    private let dbPath: URL
    private let threshold: Float
    private let confidenceMargin: Float
    /// Recent-samples FIFO size (was 5 before centroid landed; 3 is enough as
    /// fallback because the centroid is the primary anchor now).
    static let maxRecentSamples = 3
    /// Minimum total speaking time (seconds) for an embedding to be folded
    /// into the centroid. Short snippets are still kept as fallback samples
    /// but don't pollute the running average.
    static let minSpeakingTimeForCentroid: TimeInterval = 3.0

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
    /// Distance uses `min(cosineDistance over [centroid] + recent samples)`
    /// — the centroid is treated as one additional anchor alongside the
    /// recent-samples FIFO, never replacing them. This preserves the
    /// previous algorithm's behaviour on identical-sample queries while
    /// adding the centroid's drift-resistance for free.
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
                let dist = Self.distance(query: embedding, speaker: speaker)
                if dist < bestDistance {
                    secondBestDistance = bestDistance
                    bestDistance = dist
                    bestName = speaker.name
                } else if dist < secondBestDistance {
                    secondBestDistance = dist
                }
            }

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

    /// Distance from a query embedding to a stored speaker.
    /// Computes `min(cosineDistance over [centroid] + recent samples)`.
    /// For legacy entries (no centroid persisted), the recent-samples FIFO
    /// is the sole anchor — which is identical to the pre-centroid algorithm.
    static func distance(query: [Float], speaker: StoredSpeaker) -> Float {
        var anchors = speaker.embeddings
        if let c = speaker.centroid { anchors.append(c) }
        return anchors.map { cosineDistance(query, $0) }.min() ?? .greatestFiniteMagnitude
    }

    /// Element-wise mean of a non-empty list of equal-length embedding
    /// vectors. Returns nil for an empty input or for vectors of mixed
    /// dimensionality (we never produce mixed-dim arrays in normal flow,
    /// but we don't trust historical entries).
    static func meanEmbedding(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let dim = first.count
        guard vectors.allSatisfy({ $0.count == dim }) else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        for vec in vectors {
            for i in 0 ..< dim {
                sum[i] += vec[i]
            }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }

    /// Update an existing centroid with a new sample using a running average:
    /// `new = (centroid * count + sample) / (count + 1)`. Returns nil if the
    /// sample dimensionality doesn't match the centroid (we never let a bad
    /// sample corrupt the centroid).
    static func updateCentroid(
        current: [Float]?, count: Int, with sample: [Float],
    ) -> (centroid: [Float], count: Int)? {
        guard !sample.isEmpty else { return nil }
        guard let current, !current.isEmpty else {
            return (sample, 1)
        }
        guard current.count == sample.count else { return nil }
        let n = Float(count)
        let total = n + 1
        var updated = [Float](repeating: 0, count: current.count)
        for i in 0 ..< current.count {
            updated[i] = (current[i] * n + sample[i]) / total
        }
        return (updated, count + 1)
    }

    /// Update speaker DB with confirmed names and their embeddings.
    /// - Embeddings from speakers with at least `minSpeakingTimeForCentroid`
    ///   seconds of speaking time are folded into the running-mean `centroid`
    ///   (the primary match anchor).
    /// - All confirmed embeddings are appended to the recent-samples FIFO
    ///   (max `maxRecentSamples`) regardless of duration, so a borderline
    ///   centroid match can be rescued by a fallback sample distance.
    /// - `lastUsed` / `useCount` are bumped on every confirmation.
    func updateDB(
        mapping: [String: String],
        embeddings: [String: [Float]],
        speakingTimes: [String: TimeInterval] = [:],
        now: Date = Date(),
    ) {
        var stored = loadDB()

        for (label, name) in mapping {
            guard name != label, let embedding = embeddings[label] else { continue }
            let duration = speakingTimes[label] ?? 0

            if let idx = stored.firstIndex(where: { $0.name == name }) {
                stored[idx] = Self.applyConfirmation(
                    to: stored[idx],
                    embedding: embedding,
                    duration: duration,
                    now: now,
                )
            } else {
                stored.append(Self.newSpeaker(
                    name: name, embedding: embedding, duration: duration, now: now,
                ))
            }
        }

        saveDB(stored)
    }

    /// Pure helper: fold a confirmed embedding into an existing `StoredSpeaker`.
    /// Centroid is updated only when `duration >= minSpeakingTimeForCentroid`.
    /// FIFO of recent samples is bumped unconditionally.
    static func applyConfirmation(
        to speaker: StoredSpeaker, embedding: [Float], duration: TimeInterval, now: Date,
    ) -> StoredSpeaker {
        var samples = speaker.embeddings
        samples.append(embedding)
        if samples.count > maxRecentSamples {
            samples.removeFirst(samples.count - maxRecentSamples)
        }

        let qualifies = duration >= minSpeakingTimeForCentroid
        // Seed the centroid from the existing sample list on first qualifying
        // confirmation after a v3 schema upgrade. Subsequent confirmations
        // run the normal incremental update.
        let seedCentroid = speaker.centroid ?? meanEmbedding(speaker.embeddings)
        let seedCount = speaker.centroid != nil
            ? speaker.centroidSampleCount
            : (seedCentroid != nil ? speaker.embeddings.count : 0)

        let nextCentroid: [Float]?
        let nextCount: Int
        if qualifies, let updated = updateCentroid(
            current: seedCentroid, count: seedCount, with: embedding,
        ) {
            nextCentroid = updated.centroid
            nextCount = updated.count
        } else {
            nextCentroid = seedCentroid
            nextCount = seedCount
        }

        return StoredSpeaker(
            name: speaker.name,
            embeddings: samples,
            centroid: nextCentroid,
            centroidSampleCount: nextCount,
            lastUsed: now,
            useCount: speaker.useCount + 1,
        )
    }

    /// Pure helper: build a fresh `StoredSpeaker` from a single confirmation.
    static func newSpeaker(
        name: String, embedding: [Float], duration: TimeInterval, now: Date,
    ) -> StoredSpeaker {
        let qualifies = duration >= minSpeakingTimeForCentroid
        return StoredSpeaker(
            name: name,
            embeddings: [embedding],
            centroid: qualifies ? embedding : nil,
            centroidSampleCount: qualifies ? 1 : 0,
            lastUsed: now,
            useCount: 1,
        )
    }

    func loadDB() -> [StoredSpeaker] {
        guard let data = try? Data(contentsOf: dbPath) else { return [] }
        return (try? JSONDecoder().decode([StoredSpeaker].self, from: data)) ?? []
    }

    /// Names of all stored speakers, ordered for picker display: most recently
    /// used first, then by `useCount` descending, then alphabetically. Speakers
    /// without `lastUsed` (legacy entries) are sorted alphabetically at the end.
    /// This is the source-of-truth ordering for the "Known voices" row.
    func allSpeakerNames() -> [String] {
        Self.rankByRecency(speakers: loadDB()).map(\.name)
    }

    /// Sort stored speakers for picker display. Pure for testability.
    /// Tier order:
    /// 1. Speakers with `lastUsed != nil`, most recent first.
    /// 2. Within that group, ties (same timestamp) broken by `useCount` desc.
    /// 3. Speakers without `lastUsed` come last, alphabetically.
    static func rankByRecency(speakers: [StoredSpeaker]) -> [StoredSpeaker] {
        let used = speakers.filter { $0.lastUsed != nil }
        let unused = speakers.filter { $0.lastUsed == nil }
        let sortedUsed = used.sorted { lhs, rhs in
            let l = lhs.lastUsed ?? .distantPast
            let r = rhs.lastUsed ?? .distantPast
            if l != r { return l > r }
            if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let sortedUnused = unused.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return sortedUsed + sortedUnused
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

// swiftlint:enable discouraged_optional_collection
