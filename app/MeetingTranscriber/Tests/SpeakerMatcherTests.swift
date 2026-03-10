import XCTest
@testable import MeetingTranscriber

final class SpeakerMatcherTests: XCTestCase {
    var tmpDir: URL!
    var dbPath: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerMatcherTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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

    // MARK: - Update DB

    func testUpdateDBAddsNewSpeaker() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [StoredSpeaker(name: "Roman", embeddings: [[1, 0, 0]])]
        matcher.saveDB(stored)

        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman", "SPEAKER_1": "Anna"],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]]
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
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]]
        )
        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Roman")
    }

    // MARK: - Migration

    func testMigrateOldFormatResetsDB() {
        // Write old dict format (pyannote-style)
        let oldData = try! JSONSerialization.data(withJSONObject: [
            "Roman": [[1.0, 0.0, 0.0]],
        ])
        try! oldData.write(to: dbPath)

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
            participants: participants
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
            participants: participants
        )

        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
        XCTAssertEqual(result["SPEAKER_1"], "SPEAKER_1")
    }

    func testPreMatchParticipants_excludeLabels() {
        // Mic speaker excluded, remaining match → assigns
        let mapping: [String: String] = [
            "SPEAKER_0": "Roman",   // already matched (mic speaker)
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
            excludeLabels: ["SPEAKER_0"]
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
            participants: participants
        )

        XCTAssertEqual(result["SPEAKER_0"], "Roman")
        XCTAssertEqual(result["SPEAKER_1"], "Anna")
    }

    // MARK: - Multi-Embedding

    func testMigrationSingleToArray() {
        // Old format: single "embedding" key
        let oldJSON = """
        [{"name":"Roman","embedding":[1,0,0]},{"name":"Anna","embedding":[0,1,0]}]
        """
        try! oldJSON.data(using: .utf8)!.write(to: dbPath)

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
            [1, 0, 0],       // embedding from meeting 1
            [0.9, 0.3, 0],   // embedding from meeting 2
            [0.8, 0.5, 0],   // embedding from meeting 3
        ])]
        matcher.saveDB(stored)

        // New embedding close to meeting 2's embedding
        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.88, 0.35, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
    }

    func testMultiEmbeddingMaxFive() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        // Start with 5 embeddings
        let stored = [StoredSpeaker(name: "Roman", embeddings: [
            [1, 0, 0],
            [0.9, 0.1, 0],
            [0.8, 0.2, 0],
            [0.7, 0.3, 0],
            [0.6, 0.4, 0],
        ])]
        matcher.saveDB(stored)

        // Update with new embedding → should drop oldest (FIFO)
        let newEmb: [Float] = [0.5, 0.5, 0]
        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman"],
            embeddings: ["SPEAKER_0": newEmb]
        )

        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded[0].embeddings.count, 5)
        // Oldest [1, 0, 0] should be gone
        XCTAssertFalse(loaded[0].embeddings.contains([1, 0, 0]))
        // Newest should be present
        XCTAssertTrue(loaded[0].embeddings.contains(newEmb))
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
            participants: []
        )

        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
        XCTAssertEqual(result["SPEAKER_1"], "SPEAKER_1")
    }
}
