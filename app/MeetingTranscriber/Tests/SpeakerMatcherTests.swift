// swiftlint:disable file_length
@testable import MeetingTranscriber
import XCTest

// swiftlint:disable:next type_body_length
final class SpeakerMatcherTests: XCTestCase {
    /// Fixed reference timestamp used by recency-tracking tests so assertions
    /// don't depend on wall-clock time.
    private static let testEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerMatcherTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true) // swiftlint:disable:this force_try
        dbPath = tmpDir.appendingPathComponent("speakers.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Cosine distance

    func testCosineDistanceIdentical() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        XCTAssertEqual(SpeakerMatcher.cosineDistance(a, b), 0, accuracy: 0.001)
    }

    func testCosineDistanceOpposite() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        XCTAssertEqual(SpeakerMatcher.cosineDistance(a, b), 2, accuracy: 0.001)
    }

    func testCosineDistanceOrthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        XCTAssertEqual(SpeakerMatcher.cosineDistance(a, b), 1, accuracy: 0.001)
    }

    // MARK: - Match

    func testMatchEmptyDB() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let embeddings: [String: [Float]] = ["SPEAKER_0": [1, 0, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
    }

    func testMatchKnownSpeaker() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.99, 0.01, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
    }

    func testMatchTwoSpeakersNoConflict() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [
            StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Anna", embeddings: [[0, 1, 0]]),
        ]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = [
            "SPEAKER_0": [0.99, 0.01, 0],
            "SPEAKER_1": [0.01, 0.99, 0],
        ]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
        XCTAssertEqual(result["SPEAKER_1"], "Anna")
    }

    func testMatchBelowThresholdStaysUnmatched() {
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.3)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = ["SPEAKER_0": [0, 1, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
    }

    // MARK: - Save/Load

    func testSaveAndLoadDB() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let speakers = [
            StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Anna", embeddings: [[0, 1, 0]]),
        ]
        matcher.saveDB(speakers)

        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Roman")
        XCTAssertEqual(loaded[1].name, "Anna")
    }

    func testLoadDBMissing() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let loaded = matcher.loadDB()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - allSpeakerNames

    func testAllSpeakerNamesEmptyWhenNoDB() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        XCTAssertTrue(matcher.allSpeakerNames().isEmpty)
    }

    func testAllSpeakerNamesSortsAlphabeticallyCaseInsensitiveWhenUnused() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([
            StoredSpeaker(name: "charlie", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Alice", embeddings: [[0, 1, 0]]),
            StoredSpeaker(name: "bob", embeddings: [[0, 0, 1]]),
        ])
        XCTAssertEqual(matcher.allSpeakerNames(), ["Alice", "bob", "charlie"])
    }

    // MARK: - rankByRecency

    func testRankByRecencyMostRecentFirst() {
        let now = Date()
        let speakers = [
            StoredSpeaker(name: "Old", embeddings: [], lastUsed: now.addingTimeInterval(-3600), useCount: 5),
            StoredSpeaker(name: "Newest", embeddings: [], lastUsed: now, useCount: 1),
            StoredSpeaker(name: "Middle", embeddings: [], lastUsed: now.addingTimeInterval(-60), useCount: 2),
        ]
        let ranked = SpeakerMatcher.rankByRecency(speakers: speakers)
        XCTAssertEqual(ranked.map(\.name), ["Newest", "Middle", "Old"])
    }

    func testRankByRecencyTiesBrokenByUseCount() {
        let t = Date()
        let speakers = [
            StoredSpeaker(name: "Less", embeddings: [], lastUsed: t, useCount: 1),
            StoredSpeaker(name: "More", embeddings: [], lastUsed: t, useCount: 10),
        ]
        let ranked = SpeakerMatcher.rankByRecency(speakers: speakers)
        XCTAssertEqual(ranked.map(\.name), ["More", "Less"])
    }

    func testRankByRecencyLegacyEntriesAlphabeticAtEnd() {
        let now = Date()
        let speakers = [
            StoredSpeaker(name: "zelda", embeddings: []), // legacy: no lastUsed
            StoredSpeaker(name: "Newest", embeddings: [], lastUsed: now, useCount: 1),
            StoredSpeaker(name: "anna", embeddings: []), // legacy
        ]
        let ranked = SpeakerMatcher.rankByRecency(speakers: speakers)
        XCTAssertEqual(ranked.map(\.name), ["Newest", "anna", "zelda"])
    }

    // MARK: - updateDB recency tracking

    func testUpdateDBSetsLastUsedAndIncrementsUseCount() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["S0": "Anna"],
            embeddings: ["S0": [1, 0, 0]],
            now: Self.testEpoch,
        )
        let stored = matcher.loadDB()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].name, "Anna")
        XCTAssertEqual(stored[0].lastUsed, Self.testEpoch)
        XCTAssertEqual(stored[0].useCount, 1)
    }

    func testUpdateDBIncrementsUseCountForExistingSpeaker() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let later = Self.testEpoch.addingTimeInterval(1000)
        matcher.updateDB(mapping: ["S0": "Anna"], embeddings: ["S0": [1, 0, 0]], now: Self.testEpoch)
        matcher.updateDB(mapping: ["S1": "Anna"], embeddings: ["S1": [0, 1, 0]], now: later)
        let stored = matcher.loadDB()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].useCount, 2)
        XCTAssertEqual(stored[0].lastUsed, later, "lastUsed should advance to most recent confirmation")
    }

    // MARK: - Backward-compat decode

    // MARK: - meanEmbedding

    func testMeanEmbeddingSimpleAverage() {
        let mean = SpeakerMatcher.meanEmbedding([[0, 0], [2, 4]])
        XCTAssertEqual(mean, [1, 2])
    }

    func testMeanEmbeddingEmptyReturnsNil() {
        XCTAssertNil(SpeakerMatcher.meanEmbedding([]))
        XCTAssertNil(SpeakerMatcher.meanEmbedding([[]]))
    }

    func testMeanEmbeddingMixedDimensionsReturnsNil() {
        XCTAssertNil(SpeakerMatcher.meanEmbedding([[1, 2], [3, 4, 5]]))
    }

    // MARK: - updateCentroid

    func testUpdateCentroidFromNilSeedsWithSample() {
        let result = SpeakerMatcher.updateCentroid(current: nil, count: 0, with: [1, 2, 3])
        XCTAssertEqual(result?.centroid, [1, 2, 3])
        XCTAssertEqual(result?.count, 1)
    }

    func testUpdateCentroidRunningAverage() {
        // current = [2, 4] over 2 samples; new sample [4, 8] → mean = [(2*2+4)/3, (4*2+8)/3] = [8/3, 16/3]
        let result = SpeakerMatcher.updateCentroid(current: [2, 4], count: 2, with: [4, 8])
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?.centroid[0] ?? 0, 8.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(result?.centroid[1] ?? 0, 16.0 / 3.0, accuracy: 0.001)
    }

    func testUpdateCentroidMixedDimensionsReturnsNil() {
        XCTAssertNil(SpeakerMatcher.updateCentroid(current: [1, 2], count: 1, with: [1, 2, 3]))
    }

    // MARK: - applyConfirmation / newSpeaker

    func testNewSpeakerWithSufficientDurationSeedsCentroid() {
        let speaker = SpeakerMatcher.newSpeaker(
            name: "Anna", embedding: [1, 0], duration: 5.0, now: Self.testEpoch,
        )
        XCTAssertEqual(speaker.centroid, [1, 0])
        XCTAssertEqual(speaker.centroidSampleCount, 1)
        XCTAssertEqual(speaker.embeddings, [[1, 0]])
    }

    func testNewSpeakerWithShortDurationSkipsCentroid() {
        // Short snippet still appended to embeddings (fallback) but doesn't pollute centroid.
        let speaker = SpeakerMatcher.newSpeaker(
            name: "Anna", embedding: [1, 0], duration: 1.0, now: Self.testEpoch,
        )
        XCTAssertNil(speaker.centroid)
        XCTAssertEqual(speaker.centroidSampleCount, 0)
        XCTAssertEqual(speaker.embeddings, [[1, 0]])
    }

    func testApplyConfirmationFifoCapsRecentSamplesAtThree() {
        var speaker = StoredSpeaker(name: "Anna", embeddings: [[1, 0], [0, 1], [1, 1]])
        speaker = SpeakerMatcher.applyConfirmation(
            to: speaker, embedding: [2, 2], duration: 5, now: Self.testEpoch,
        )
        XCTAssertEqual(speaker.embeddings.count, SpeakerMatcher.maxRecentSamples)
        XCTAssertEqual(speaker.embeddings.last, [2, 2])
        XCTAssertEqual(speaker.embeddings.first, [0, 1], "oldest sample dropped")
    }

    func testApplyConfirmationSeedsCentroidFromLegacySamplesOnFirstQualifyingConfirmation() {
        // Legacy entry: pre-v3, no centroid yet, embeddings populated.
        let legacy = StoredSpeaker(name: "Anna", embeddings: [[1, 0], [0, 1]])
        let updated = SpeakerMatcher.applyConfirmation(
            to: legacy, embedding: [2, 2], duration: 5, now: Self.testEpoch,
        )
        // Seed: meanEmbedding(legacy.embeddings) = [0.5, 0.5] over 2 samples,
        // then folded with [2, 2] → ((0.5*2+2)/3, (0.5*2+2)/3) = (1.0, 1.0)
        XCTAssertNotNil(updated.centroid)
        XCTAssertEqual(updated.centroid?[0] ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(updated.centroid?[1] ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(updated.centroidSampleCount, 3)
    }

    func testApplyConfirmationShortSnippetDoesNotMoveExistingCentroid() {
        let speaker = StoredSpeaker(
            name: "Anna",
            embeddings: [[1, 0]],
            centroid: [1, 0],
            centroidSampleCount: 1,
        )
        let updated = SpeakerMatcher.applyConfirmation(
            to: speaker, embedding: [9, 9], duration: 0.5, now: Self.testEpoch,
        )
        XCTAssertEqual(updated.centroid, [1, 0], "short snippet must not pollute centroid")
        XCTAssertEqual(updated.centroidSampleCount, 1)
        XCTAssertEqual(updated.embeddings.count, 2, "but is still kept as fallback sample")
    }

    // MARK: - updateDB recency tracking with quality filter

    func testUpdateDBPersistsCentroidWhenSpeakingTimeQualifies() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["S0": "Anna"],
            embeddings: ["S0": [1, 0]],
            speakingTimes: ["S0": 5.0],
            now: Self.testEpoch,
        )
        let stored = matcher.loadDB()
        XCTAssertEqual(stored.first?.centroid, [1, 0])
        XCTAssertEqual(stored.first?.centroidSampleCount, 1)
    }

    func testUpdateDBSkipsCentroidWhenSpeakingTimeShort() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["S0": "Anna"],
            embeddings: ["S0": [1, 0]],
            speakingTimes: ["S0": 1.0],
            now: Self.testEpoch,
        )
        let stored = matcher.loadDB()
        XCTAssertNil(stored.first?.centroid)
        XCTAssertEqual(stored.first?.embeddings, [[1, 0]])
    }

    // MARK: - match with centroid

    func testMatchPrefersCentroidOverNoisySample() {
        // A speaker whose centroid says "[1, 0]" but whose embeddings list has
        // a noisy outlier "[0.7, 0.7]". A query "[0.99, 0.01]" should match.
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.5)
        matcher.saveDB([StoredSpeaker(
            name: "Anna",
            embeddings: [[1, 0], [0.7, 0.7]],
            centroid: [1, 0],
            centroidSampleCount: 5,
        )])
        let result = matcher.match(embeddings: ["S0": [0.99, 0.01]])
        XCTAssertEqual(result["S0"], "Anna")
    }

    func testMatchUsesSamplesAsFallbackForLegacyEntries() {
        // Legacy entry: no centroid; matcher should compute meanEmbedding lazily.
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.5)
        matcher.saveDB([StoredSpeaker(name: "Anna", embeddings: [[1, 0]])])
        let result = matcher.match(embeddings: ["S0": [0.99, 0.01]])
        XCTAssertEqual(result["S0"], "Anna")
    }

    // MARK: - Backward-compat decode

    func testLoadDBDecodesLegacyEntriesWithoutCentroidFields() throws {
        // Pre-v3 entries decode with centroid=nil, centroidSampleCount=0.
        let legacy = """
        [{"name":"Roman","embeddings":[[1,0,0]],"lastUsed":700000000,"useCount":3}]
        """
        try legacy.data(using: .utf8)?.write(to: dbPath)
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = matcher.loadDB()
        XCTAssertNil(stored[0].centroid)
        XCTAssertEqual(stored[0].centroidSampleCount, 0)
        XCTAssertEqual(stored[0].useCount, 3)
    }

    func testLoadDBDecodesLegacyEntriesWithoutRecencyFields() throws {
        // Older speakers.json predates lastUsed/useCount — decode must default them.
        let legacy = """
        [{"name":"Roman","embeddings":[[1,0,0]]}]
        """
        try legacy.data(using: .utf8)?.write(to: dbPath)
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = matcher.loadDB()
        XCTAssertEqual(stored.count, 1)
        XCTAssertNil(stored[0].lastUsed)
        XCTAssertEqual(stored[0].useCount, 0)
    }

    // MARK: - Update DB

    func testUpdateDBAddsNewSpeaker() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman", "SPEAKER_1": "Anna"],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )

        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded.count, 2)
        let names = Set(loaded.map(\.name))
        XCTAssertTrue(names.contains("Roman"))
        XCTAssertTrue(names.contains("Anna"))
    }

    func testUpdateDBSkipsUnnamedSpeakers() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman", "SPEAKER_1": "SPEAKER_1"],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )
        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Roman")
    }

    // MARK: - Migration

    func testMigrateOldFormatResetsDB() throws {
        // Write old dict format (pyannote-style)
        let oldData = try JSONSerialization.data(withJSONObject: [
            "Roman": [[1.0, 0.0, 0.0]],
        ])
        try oldData.write(to: dbPath)

        SpeakerMatcher.migrateIfNeeded(dbPath: dbPath)

        // Old file should be gone (backed up)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath.path))
        let backup = dbPath.deletingLastPathComponent()
            .appendingPathComponent("speakers.json.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testMigrateNewFormatKeepsDB() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])])

        SpeakerMatcher.migrateIfNeeded(dbPath: dbPath)

        // Should still exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath.path))
    }

    // MARK: - Pre-match participants

    func testPreMatchParticipants_exactMatch() {
        // 2 unmatched speakers, 2 participants → assigns by speaking time
        let mapping: [String: String] = [
            "SPEAKER_0": "SPEAKER_0",
            "SPEAKER_1": "SPEAKER_1",
        ]
        let speakingTimes: [String: TimeInterval] = [
            "SPEAKER_0": 30.0,
            "SPEAKER_1": 90.0,
        ]
        let participants = ["Alice", "Bob"]

        let result = SpeakerMatcher.preMatchParticipants(
            mapping: mapping,
            speakingTimes: speakingTimes,
            participants: participants,
        )

        // SPEAKER_1 spoke more → gets first participant (Alice)
        XCTAssertEqual(result["SPEAKER_1"], "Alice")
        XCTAssertEqual(result["SPEAKER_0"], "Bob")
    }

    func testPreMatchParticipants_countMismatch() {
        // 2 unmatched, 3 participants → no change
        let mapping: [String: String] = [
            "SPEAKER_0": "SPEAKER_0",
            "SPEAKER_1": "SPEAKER_1",
        ]
        let speakingTimes: [String: TimeInterval] = [
            "SPEAKER_0": 30.0,
            "SPEAKER_1": 90.0,
        ]
        let participants = ["Alice", "Bob", "Charlie"]

        let result = SpeakerMatcher.preMatchParticipants(
            mapping: mapping,
            speakingTimes: speakingTimes,
            participants: participants,
        )

        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
        XCTAssertEqual(result["SPEAKER_1"], "SPEAKER_1")
    }

    func testPreMatchParticipants_excludeLabels() {
        // Mic speaker excluded, remaining match → assigns
        let mapping: [String: String] = [
            "SPEAKER_0": "Roman", // already matched (mic speaker)
            "SPEAKER_1": "SPEAKER_1",
            "SPEAKER_2": "SPEAKER_2",
        ]
        let speakingTimes: [String: TimeInterval] = [
            "SPEAKER_0": 50.0,
            "SPEAKER_1": 80.0,
            "SPEAKER_2": 20.0,
        ]
        let participants = ["Roman", "Alice", "Bob"]

        let result = SpeakerMatcher.preMatchParticipants(
            mapping: mapping,
            speakingTimes: speakingTimes,
            participants: participants,
            excludeLabels: ["SPEAKER_0"],
        )

        // Roman is already used, so unused = [Alice, Bob]
        // SPEAKER_1 spoke more → Alice, SPEAKER_2 → Bob
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
        XCTAssertEqual(result["SPEAKER_1"], "Alice")
        XCTAssertEqual(result["SPEAKER_2"], "Bob")
    }

    func testPreMatchParticipants_noUnmatched() {
        // All already named → no change
        let mapping: [String: String] = [
            "SPEAKER_0": "Roman",
            "SPEAKER_1": "Anna",
        ]
        let speakingTimes: [String: TimeInterval] = [
            "SPEAKER_0": 50.0,
            "SPEAKER_1": 80.0,
        ]
        let participants = ["Roman", "Anna"]

        let result = SpeakerMatcher.preMatchParticipants(
            mapping: mapping,
            speakingTimes: speakingTimes,
            participants: participants,
        )

        XCTAssertEqual(result["SPEAKER_0"], "Roman")
        XCTAssertEqual(result["SPEAKER_1"], "Anna")
    }

    // MARK: - Multi-Embedding

    func testMigrationSingleToArray() throws {
        // Old format: single "embedding" key
        let oldJSON = """
        [{"name":"Roman","embedding":[1,0,0]},{"name":"Anna","embedding":[0,1,0]}]
        """
        try oldJSON.data(using: .utf8)?.write(to: dbPath)

        let matcher = SpeakerMatcher(dbPath: dbPath)
        let loaded = matcher.loadDB()

        // Should auto-migrate to embeddings array
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Roman")
        XCTAssertEqual(loaded[0].embeddings.count, 1)
        XCTAssertEqual(loaded[0].embeddings[0], [1, 0, 0])
    }

    func testMultiEmbeddingMatchesBest() {
        // Speaker has 3 stored embeddings, match against the closest one
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [
            [1, 0, 0], // embedding from meeting 1
            [0.9, 0.3, 0], // embedding from meeting 2
            [0.8, 0.5, 0], // embedding from meeting 3
        ])]
        matcher.saveDB(stored)

        // New embedding close to meeting 2's embedding
        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.88, 0.35, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
    }

    func testRecentSamplesFifoCappedAtMaxRecentSamples() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [
            [1, 0, 0],
            [0.9, 0.1, 0],
            [0.8, 0.2, 0],
        ])]
        matcher.saveDB(stored)

        // Update with new embedding → should drop oldest (FIFO).
        let newEmb: [Float] = [0.5, 0.5, 0]
        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman"],
            embeddings: ["SPEAKER_0": newEmb],
        )

        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded[0].embeddings.count, SpeakerMatcher.maxRecentSamples)
        XCTAssertFalse(loaded[0].embeddings.contains([1, 0, 0]), "oldest sample dropped")
        XCTAssertTrue(loaded[0].embeddings.contains(newEmb), "newest sample present")
    }

    // MARK: - Confidence Margin

    func testConfidenceMarginRejectsAmbiguous() {
        // Two stored speakers with similar distance → no match
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.40, confidenceMargin: 0.10)
        let stored = [
            StoredSpeaker(name: "Roman", embeddings: [[0.9, 0.3, 0]]),
            StoredSpeaker(name: "Anna", embeddings: [[0.85, 0.35, 0]]),
        ]
        matcher.saveDB(stored)

        // Embedding equidistant to both → ambiguous → no match
        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.87, 0.33, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
    }

    func testConfidenceMarginAcceptsClear() {
        // One clearly closer than the other → match
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.40, confidenceMargin: 0.10)
        let stored = [
            StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Anna", embeddings: [[0, 1, 0]]),
        ]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.98, 0.05, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
    }

    func testStricterThresholdRejectsLooseMatch() {
        // Distance ~0.50 — would match with old 0.65, rejected with 0.40
        // cos([1,0,0], [0.5,0.866,0]) = 0.5 → distance = 0.50
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.40)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.5, 0.866, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
    }

    // MARK: - Cosine Distance Edge Cases

    func testCosineDistanceEmptyVectors() {
        let result = SpeakerMatcher.cosineDistance([], [])
        XCTAssertEqual(result, 2, accuracy: 0.001)
    }

    func testCosineDistanceMismatchedLengths() {
        let result = SpeakerMatcher.cosineDistance([1, 0], [1, 0, 0])
        XCTAssertEqual(result, 2, accuracy: 0.001)
    }

    func testCosineDistanceZeroVector() {
        let result = SpeakerMatcher.cosineDistance([0, 0, 0], [1, 0, 0])
        XCTAssertEqual(result, 2, accuracy: 0.001)
    }

    // MARK: - StoredSpeaker Decoding Edge Cases

    func testDecodeSpeakerWithNoEmbeddings() throws {
        let json = """
        [{"name":"Ghost"}]
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let speakers = try JSONDecoder().decode([StoredSpeaker].self, from: data)
        XCTAssertEqual(speakers[0].name, "Ghost")
        XCTAssertTrue(speakers[0].embeddings.isEmpty)
    }

    func testPreMatchParticipants_emptyParticipants() {
        // No participants → no change
        let mapping: [String: String] = [
            "SPEAKER_0": "SPEAKER_0",
            "SPEAKER_1": "SPEAKER_1",
        ]
        let speakingTimes: [String: TimeInterval] = [
            "SPEAKER_0": 50.0,
            "SPEAKER_1": 80.0,
        ]

        let result = SpeakerMatcher.preMatchParticipants(
            mapping: mapping,
            speakingTimes: speakingTimes,
            participants: [],
        )

        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
        XCTAssertEqual(result["SPEAKER_1"], "SPEAKER_1")
    }

    // MARK: - Additional Edge Cases

    func testMatchSingleSpeakerOneStored() {
        // Only one speaker to match against one stored → should match
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.40, confidenceMargin: 0.10)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.95, 0.1, 0]]
        let result = matcher.match(embeddings: embeddings)
        // Single stored speaker → no confidence margin needed
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
    }

    func testPreMatchParticipants_singleSpeakerSingleParticipant() {
        let mapping = ["SPEAKER_0": "SPEAKER_0"]
        let speakingTimes: [String: TimeInterval] = ["SPEAKER_0": 120.0]
        let participants = ["Alice"]

        let result = SpeakerMatcher.preMatchParticipants(
            mapping: mapping,
            speakingTimes: speakingTimes,
            participants: participants,
        )
        XCTAssertEqual(result["SPEAKER_0"], "Alice")
    }

    func testUpdateDBDoesNotDuplicateExistingSpeaker() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])])

        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman"],
            embeddings: ["SPEAKER_0": [0.95, 0.1, 0]],
        )

        let loaded = matcher.loadDB()
        // Should still be just one speaker, not two
        let romanCount = loaded.count { $0.name == "Roman" }
        XCTAssertEqual(romanCount, 1)
        // Should have 2 embeddings now
        XCTAssertEqual(loaded.first { $0.name == "Roman" }?.embeddings.count, 2)
    }

    func testMatchWithEmptyEmbeddingsReturnsOriginal() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        let result = matcher.match(embeddings: [:])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Corrupt DB & Edge Cases

    func testLoadDBCorruptJSONReturnsEmpty() throws {
        // Write invalid JSON to dbPath — loadDB should return empty, not crash
        let garbage = Data("{ not valid json !!!".utf8)
        try garbage.write(to: dbPath)

        let matcher = SpeakerMatcher(dbPath: dbPath)
        let loaded = matcher.loadDB()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testLoadDBEmptyFileReturnsEmpty() throws {
        // Write zero bytes — loadDB should return empty
        try Data().write(to: dbPath)

        let matcher = SpeakerMatcher(dbPath: dbPath)
        let loaded = matcher.loadDB()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testUpdateDBWithMissingEmbeddingIsNoOp() {
        // Mapping has a named speaker but embeddings dict is empty → no DB entry created
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman"],
            embeddings: [:],
        )

        let loaded = matcher.loadDB()
        XCTAssertTrue(loaded.isEmpty, "No embedding provided, so nothing should be stored")
    }

    func testMatchThreeSpeakersTwoStored() {
        // 3 input embeddings, 2 stored speakers → third stays unmatched
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.40, confidenceMargin: 0.10)
        let stored = [
            StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Anna", embeddings: [[0, 1, 0]]),
        ]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = [
            "SPEAKER_0": [0.98, 0.05, 0], // close to Roman
            "SPEAKER_1": [0.05, 0.98, 0], // close to Anna
            "SPEAKER_2": [0, 0, 1], // no match in DB
        ]
        let result = matcher.match(embeddings: embeddings)

        XCTAssertEqual(result["SPEAKER_0"], "Roman")
        XCTAssertEqual(result["SPEAKER_1"], "Anna")
        XCTAssertEqual(result["SPEAKER_2"], "SPEAKER_2", "Third speaker should stay unmatched")
    }

    func testMatchIsDeterministicByKey() {
        // Two speakers both close to the same stored speaker.
        // Sorted by key, SPEAKER_0 < SPEAKER_1, so SPEAKER_0 claims the match first.
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.40, confidenceMargin: 0.0)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = [
            "SPEAKER_0": [0.95, 0.1, 0], // close to Roman
            "SPEAKER_1": [0.96, 0.08, 0], // also close to Roman (even closer)
        ]
        let result = matcher.match(embeddings: embeddings)

        // SPEAKER_0 is processed first (alphabetical) and claims "Roman"
        XCTAssertEqual(result["SPEAKER_0"], "Roman", "First key alphabetically should win the match")
        XCTAssertEqual(result["SPEAKER_1"], "SPEAKER_1", "Second speaker left unmatched")
    }

    // MARK: - matchVerbose

    func testMatchVerboseReturnsRankedCandidates() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [
            StoredSpeaker(name: "Speaker A", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Speaker B", embeddings: [[0, 1, 0]]),
            StoredSpeaker(name: "Speaker C", embeddings: [[0, 0, 1]]),
        ]
        matcher.saveDB(stored)

        let result = matcher.matchVerbose(embeddings: ["SPEAKER_0": [0.99, 0.01, 0]])
        let entry = result["SPEAKER_0"]

        XCTAssertEqual(entry?.assignedName, "Speaker A")
        XCTAssertEqual(entry?.topCandidates.count, 3)
        XCTAssertEqual(entry?.topCandidates.first?.name, "Speaker A")
        // Speaker A is closest; the other two are orthogonal at distance 1.
        XCTAssertLessThan(entry?.topCandidates.first?.hybrid ?? 1, 0.1)
    }

    func testMatchVerboseExposesCentroidDistance() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [
            StoredSpeaker(
                name: "Speaker A", embeddings: [[1, 0, 0]],
                centroid: [0.9, 0.1, 0], centroidSampleCount: 5,
            ),
        ]
        matcher.saveDB(stored)

        let result = matcher.matchVerbose(embeddings: ["S0": [1, 0, 0]])
        let cand = result["S0"]?.topCandidates.first
        XCTAssertEqual(cand?.name, "Speaker A")
        XCTAssertNotNil(cand?.centroid, "Centroid distance should be reported when stored")
        XCTAssertEqual(cand?.sample ?? 1, 0, accuracy: 0.001)
    }

    func testMatchVerboseLegacyEntriesHaveNilCentroid() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        // No centroid persisted (legacy entry)
        let stored = [StoredSpeaker(name: "Speaker A", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        let result = matcher.matchVerbose(embeddings: ["S0": [1, 0, 0]])
        XCTAssertNil(result["S0"]?.topCandidates.first?.centroid)
    }

    func testMatchVerboseAssignsLabelWhenBelowConfidenceMargin() {
        let matcher = SpeakerMatcher(dbPath: dbPath, confidenceMargin: 0.5)
        let stored = [
            StoredSpeaker(name: "Speaker A", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Speaker B", embeddings: [[0.99, 0.01, 0]]),
        ]
        matcher.saveDB(stored)

        let result = matcher.matchVerbose(embeddings: ["S0": [1, 0, 0]])
        XCTAssertEqual(result["S0"]?.assignedName, "S0")
        // Both candidates still surfaced
        XCTAssertEqual(result["S0"]?.topCandidates.count, 2)
    }
}
