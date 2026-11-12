@testable import MeetingTranscriber
import XCTest

// The centroid must only ever hold embeddings from segments of at least
// `minSpeakingTimeForCentroid`. The fixtures point the short sample and the
// long sample in orthogonal directions, so a centroid that wrongly folds the
// short one in is measurably off the long one.
// swiftlint:disable:next balanced_xctest_lifecycle
final class SpeakerCentroidSeedingTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let shortSample: [Float] = [0, 1]
    private static let longSample: [Float] = [1, 0]
    private static let short: TimeInterval = 1
    private static let long: TimeInterval = 5

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dbPath: URL!

    override func setUpWithError() throws {
        dbPath = try makeTempDirectory(prefix: "SpeakerCentroidSeedingTests")
            .appendingPathComponent("speakers.json")
    }

    private func confirm(_ speaker: StoredSpeaker, _ embedding: [Float], _ duration: TimeInterval) -> StoredSpeaker {
        SpeakerMatcher.applyConfirmation(to: speaker, embedding: embedding, duration: duration, now: Self.now)
    }

    private func fresh(_ name: String, _ embedding: [Float], _ duration: TimeInterval) -> StoredSpeaker {
        SpeakerMatcher.newSpeaker(name: name, embedding: embedding, duration: duration, now: Self.now)
    }

    private func assertCentroid(
        _ speaker: StoredSpeaker, equals expected: [Float], count: Int,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        let centroid = speaker.centroid ?? []
        XCTAssertEqual(centroid.count, expected.count, "centroid \(String(describing: speaker.centroid))", file: file, line: line)
        for (got, want) in zip(centroid, expected) {
            XCTAssertEqual(got, want, accuracy: 0.001, "centroid \(centroid)", file: file, line: line)
        }
        XCTAssertEqual(speaker.centroidSampleCount, count, file: file, line: line)
    }

    // MARK: - A short first sample never reaches the centroid

    func testQualifyingConfirmationAfterShortFirstSampleUsesOnlyTheQualifyingSample() {
        let speaker = confirm(fresh("Speaker A", Self.shortSample, Self.short), Self.longSample, Self.long)
        assertCentroid(speaker, equals: Self.longSample, count: 1)
        XCTAssertEqual(speaker.embeddings, [Self.shortSample, Self.longSample], "the short sample stays a fallback")
        XCTAssertFalse(speaker.awaitsQualifyingSample, "the marker goes once a centroid exists")
    }

    func testShortConfirmationAfterShortFirstSampleLeavesTheCentroidEmpty() {
        let speaker = confirm(fresh("Speaker A", Self.shortSample, Self.short), Self.shortSample, Self.short)
        XCTAssertNil(speaker.centroid, "no qualifying sample was ever confirmed")
        XCTAssertEqual(speaker.centroidSampleCount, 0)
    }

    /// The same two confirmations through `updateDB`, so the state between
    /// them goes through `speakers.json` and has to survive a save and load.
    func testShortThenQualifyingConfirmationThroughTheDatabase() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["S0": "Speaker A"], embeddings: ["S0": Self.shortSample],
            speakingTimes: ["S0": Self.short], now: Self.now,
        )
        matcher.updateDB(
            mapping: ["S0": "Speaker A"], embeddings: ["S0": Self.shortSample],
            speakingTimes: ["S0": Self.short], now: Self.now,
        )
        XCTAssertNil(matcher.loadDB().first?.centroid, "two short confirmations persist no centroid")

        matcher.updateDB(
            mapping: ["S0": "Speaker A"], embeddings: ["S0": Self.longSample],
            speakingTimes: ["S0": Self.long], now: Self.now,
        )
        try assertCentroid(XCTUnwrap(matcher.loadDB().first), equals: Self.longSample, count: 1)
    }

    /// An entry written before the centroid existed has samples of unknown
    /// quality, and those still seed the centroid on the first qualifying
    /// confirmation, as they always did.
    func testLegacyEntryFromAnOldDatabaseIsStillSeededFromItsSamples() throws {
        try Data(#"[{"name":"Speaker A","embeddings":[[0,1]],"lastUsed":700000000,"useCount":2}]"#.utf8)
            .write(to: dbPath)
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["S0": "Speaker A"], embeddings: ["S0": Self.longSample],
            speakingTimes: ["S0": Self.long], now: Self.now,
        )
        let stored = try XCTUnwrap(matcher.loadDB().first)
        assertCentroid(stored, equals: [0.5, 0.5], count: 2)
    }

    /// A legacy entry confirmed on a short segment persists the seed from its
    /// old samples. Matching then uses that seed as an anchor, and the short
    /// sample now in the FIFO can no longer seed the centroid later.
    func testShortConfirmationOfALegacyEntryFreezesTheSeedWithoutTheShortSample() {
        let legacy = StoredSpeaker(name: "Speaker A", embeddings: [Self.longSample])
        let afterShort = confirm(legacy, Self.shortSample, Self.short)
        assertCentroid(afterShort, equals: Self.longSample, count: 1)
        assertCentroid(confirm(afterShort, Self.longSample, Self.long), equals: Self.longSample, count: 2)
    }

    // MARK: - merged

    /// A legacy side seeds the merged centroid from its own samples only; the
    /// awaiting side's short samples stay out, whichever side is merged into
    /// which.
    func testMergingALegacyEntryWithAnAwaitingEntrySeedsFromTheLegacySamplesOnly() {
        let legacy = StoredSpeaker(name: "Speaker A", embeddings: [Self.longSample])
        let awaiting = fresh("Speaker B", Self.shortSample, Self.short)
        for merged in [
            SpeakerMatcher.merged(into: legacy, from: awaiting),
            SpeakerMatcher.merged(into: awaiting, from: legacy),
        ] {
            assertCentroid(merged, equals: Self.longSample, count: 1)
            XCTAssertFalse(merged.awaitsQualifyingSample)
        }
    }

    func testMergingTwoEntriesWithOnlyShortSamplesKeepsTheCentroidEmpty() {
        let merged = SpeakerMatcher.merged(
            into: fresh("Speaker A", Self.shortSample, Self.short),
            from: fresh("Speaker B", Self.shortSample, Self.short),
        )
        XCTAssertNil(merged.centroid, "neither side ever had a qualifying sample")
        assertCentroid(confirm(merged, Self.longSample, Self.long), equals: Self.longSample, count: 1)
    }

    /// Two legacy entries merge into the mean of their samples; the next
    /// confirmation must weigh that mean by the samples it holds rather than
    /// replace it outright.
    func testMergedLegacyCentroidKeepsItsWeightOnTheNextConfirmation() {
        let merged = SpeakerMatcher.merged(
            into: StoredSpeaker(name: "Speaker A", embeddings: [[0, 1]]),
            from: StoredSpeaker(name: "Speaker B", embeddings: [[0, 1]]),
        )
        assertCentroid(merged, equals: [0, 1], count: 2)
        assertCentroid(confirm(merged, Self.longSample, Self.long), equals: [1.0 / 3, 2.0 / 3], count: 3)
    }

    /// Databases written by earlier merges hold a centroid with a count of
    /// zero. That centroid is real and must not be thrown away by the next
    /// confirmation, nor zeroed by another merge.
    func testPersistedCentroidWithZeroCountIsNotDiscarded() {
        let damaged = StoredSpeaker(name: "Speaker A", embeddings: [[0, 1]], centroid: [0, 1], centroidSampleCount: 0)
        assertCentroid(confirm(damaged, Self.longSample, Self.long), equals: [0.5, 0.5], count: 2)

        let merged = SpeakerMatcher.merged(into: damaged, from: damaged)
        assertCentroid(merged, equals: [0, 1], count: 2)
    }

    /// Merging two centroids that both had a count of zero used to write an
    /// all-zero vector. It has no direction, so it counts as no centroid: the
    /// entry seeds from its samples like a legacy one, and a merge takes the
    /// other side's centroid unchanged.
    func testAllZeroCentroidCountsAsAbsent() {
        let zeroed = StoredSpeaker(name: "Speaker A", embeddings: [Self.shortSample], centroid: [0, 0])
        assertCentroid(confirm(zeroed, Self.longSample, Self.long), equals: [0.5, 0.5], count: 2)

        let real = StoredSpeaker(name: "Speaker B", embeddings: [Self.longSample], centroid: Self.longSample, centroidSampleCount: 1)
        assertCentroid(SpeakerMatcher.merged(into: zeroed, from: real), equals: Self.longSample, count: 1)
    }
}
