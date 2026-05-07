// swiftlint:disable discouraged_optional_collection
// `centroid: [Float]?` and `lastUsed: Date?` use nil to signal a distinct
// "absent" state (no centroid yet / never confirmed), which an empty
// collection cannot express.
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
    /// True for entries seeded by the debug RPC `seedSpeaker` action, which
    /// writes random embeddings for testing. Synthetic entries are skipped
    /// in `match()`/`matchVerbose()` so a poisoned random vector can never
    /// auto-name a real speaker. Defaults to false for legacy entries and
    /// for every user-confirmed speaker.
    let isSynthetic: Bool

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
        isSynthetic = try container.decodeIfPresent(Bool.self, forKey: .isSynthetic) ?? false
    }

    init(
        name: String,
        embeddings: [[Float]],
        centroid: [Float]? = nil,
        centroidSampleCount: Int = 0,
        lastUsed: Date? = nil,
        useCount: Int = 0,
        isSynthetic: Bool = false,
    ) {
        self.name = name
        self.embeddings = embeddings
        self.centroid = centroid
        self.centroidSampleCount = centroidSampleCount
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.isSynthetic = isSynthetic
    }

    private enum CodingKeys: String, CodingKey {
        case name, embeddings, embedding, centroid, centroidSampleCount,
             lastUsed, useCount, isSynthetic
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
        // Same byte-identity rule for legacy entries.
        if isSynthetic {
            try container.encode(isSynthetic, forKey: .isSynthetic)
        }
    }

    /// Copy of this speaker with a new `name`, preserving all other fields.
    /// Used by `SpeakerMatcher.renameSpeaker`; centralises the field list so
    /// future additions don't have to be threaded through the rename site.
    func renamed(to newName: String) -> Self {
        Self(
            name: newName,
            embeddings: embeddings,
            centroid: centroid,
            centroidSampleCount: centroidSampleCount,
            lastUsed: lastUsed,
            useCount: useCount,
            isSynthetic: isSynthetic,
        )
    }
}

// swiftlint:enable discouraged_optional_collection
