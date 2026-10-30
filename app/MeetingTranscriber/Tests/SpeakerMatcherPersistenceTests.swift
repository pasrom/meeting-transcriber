@testable import MeetingTranscriber
import XCTest

/// `speakers.json` is the one persisted store whose loss cannot be recovered
/// by re-running a job, so these pin that no write path can silently drop it.
final class SpeakerMatcherPersistenceTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUpWithError() throws {
        tmpDir = try makeTempDirectory(prefix: "SpeakerMatcherPersistenceTests")
        dbPath = tmpDir.appendingPathComponent("speakers.json")
    }

    // MARK: - Non-finite embeddings

    func testNonFiniteEmbeddingIsSkippedWithoutLosingTheMutation() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]], centroid: [1, 0, 0])])

        matcher.updateDB(
            mapping: ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob"],
            embeddings: [
                "SPEAKER_0": [0.9, 0.1, 0],
                "SPEAKER_1": [.nan, .infinity, -.infinity],
            ],
            speakingTimes: ["SPEAKER_0": 10],
        )
        // A NaN for an existing speaker must not reach its running-mean centroid.
        matcher.updateDB(
            mapping: ["SPEAKER_0": "Alice"],
            embeddings: ["SPEAKER_0": [.nan, 0, 0]],
            speakingTimes: ["SPEAKER_0": 10],
        )

        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded.map(\.name), ["Alice"], "the non-finite label is skipped")
        let alice = try XCTUnwrap(loaded.first)
        XCTAssertEqual(alice.useCount, 1, "only the finite confirmation counts, and it must persist")
        XCTAssertTrue(try XCTUnwrap(alice.centroid).allSatisfy(\.isFinite))
        XCTAssertTrue(alice.embeddings.joined().allSatisfy(\.isFinite))
    }
}
