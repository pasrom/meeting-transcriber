@testable import MeetingTranscriber
import XCTest

/// `StoredSpeaker.encode` deliberately omits `centroidSampleCount` / `useCount` /
/// `isSynthetic` when they hold their zero/false default, and `centroid` /
/// `lastUsed` when nil, so a `speakers.json` written before those fields existed
/// round-trips byte-identically (no spurious keys added on first save). These
/// tests pin that omission contract — an unconditional encode would silently
/// rewrite every legacy DB entry on first load.
final class StoredSpeakerCodingTests: XCTestCase {
    private func encodedKeys(_ speaker: StoredSpeaker) throws -> Set<String> {
        let data = try JSONEncoder().encode(speaker)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(obj.keys)
    }

    func testOmitsDefaultFieldsForLegacyStyleEntry() throws {
        let speaker = StoredSpeaker(name: "Speaker A", embeddings: [[0.1, 0.2]])
        XCTAssertEqual(
            try encodedKeys(speaker), ["name", "embeddings"],
            "a zero/false/nil entry must encode only name + embeddings",
        )
    }

    func testEmitsEveryFieldOncePopulated() throws {
        let speaker = StoredSpeaker(
            name: "Speaker B",
            embeddings: [[0.1, 0.2]],
            centroid: [0.15, 0.2],
            centroidSampleCount: 3,
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
            useCount: 5,
            isSynthetic: true,
        )
        XCTAssertEqual(
            try encodedKeys(speaker),
            ["name", "embeddings", "centroid", "centroidSampleCount", "lastUsed", "useCount", "isSynthetic"],
            "a fully-populated entry must encode every field",
        )
    }

    func testZeroCountAndFalseSyntheticAreOmittedIndividually() throws {
        // useCount > 0 but the other two still default → only useCount appears.
        let speaker = StoredSpeaker(name: "Speaker C", embeddings: [[0.1]], useCount: 2)
        let keys = try encodedKeys(speaker)
        XCTAssertTrue(keys.contains("useCount"), "a non-zero useCount must be encoded")
        XCTAssertFalse(keys.contains("centroidSampleCount"), "a zero centroidSampleCount must stay omitted")
        XCTAssertFalse(keys.contains("isSynthetic"), "a false isSynthetic must stay omitted")
    }

    func testRoundTripsPopulatedEntry() throws {
        let original = StoredSpeaker(
            name: "Speaker D",
            embeddings: [[0.1, 0.2], [0.3, 0.4]],
            centroid: [0.2, 0.3],
            centroidSampleCount: 2,
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
            useCount: 4,
            isSynthetic: true,
        )
        let decoded = try JSONDecoder().decode(
            StoredSpeaker.self, from: JSONEncoder().encode(original),
        )
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.embeddings, original.embeddings)
        XCTAssertEqual(decoded.centroid, original.centroid)
        XCTAssertEqual(decoded.centroidSampleCount, original.centroidSampleCount)
        XCTAssertEqual(decoded.lastUsed, original.lastUsed)
        XCTAssertEqual(decoded.useCount, original.useCount)
        XCTAssertEqual(decoded.isSynthetic, original.isSynthetic)
    }
}
