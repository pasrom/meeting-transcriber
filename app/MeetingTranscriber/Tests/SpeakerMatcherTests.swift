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
        let stored = [StoredSpeaker(name: "Roman", embedding: [1, 0, 0])]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.99, 0.01, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
    }

    func testMatchTwoSpeakersNoConflict() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [
            StoredSpeaker(name: "Roman", embedding: [1, 0, 0]),
            StoredSpeaker(name: "Anna", embedding: [0, 1, 0]),
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
        let stored = [StoredSpeaker(name: "Roman", embedding: [1, 0, 0])]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = ["SPEAKER_0": [0, 1, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
    }

    // MARK: - Save/Load

    func testSaveAndLoadDB() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let speakers = [
            StoredSpeaker(name: "Roman", embedding: [1, 0, 0]),
            StoredSpeaker(name: "Anna", embedding: [0, 1, 0]),
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
        let stored = [StoredSpeaker(name: "Roman", embedding: [1, 0, 0])]
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
}
