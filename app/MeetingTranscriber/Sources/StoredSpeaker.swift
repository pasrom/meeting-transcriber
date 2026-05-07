// swiftlint:disable discouraged_optional_collection
// Optional `[Float]?` is intentional: nil signals "no centroid yet" (legacy
// entries / dim-mismatch / empty input), which is semantically distinct from
// an empty embedding vector.
import Foundation

struct StoredSpeaker: Codable, Identifiable {
    var id: String {
        name
    }

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

// swiftlint:enable discouraged_optional_collection
