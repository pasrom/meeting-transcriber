import Foundation
@testable import MeetingTranscriber
import XCTest

final class RecognitionStatsTests: XCTestCase {
    // MARK: - classify

    func testClassifyAccepted() {
        XCTAssertEqual(RecognitionStats.classify(autoName: "Speaker A", userName: "Speaker A"), .accepted)
    }

    func testClassifyCorrected() {
        XCTAssertEqual(RecognitionStats.classify(autoName: "Speaker A", userName: "Speaker B"), .corrected)
    }

    func testClassifyAdded() {
        XCTAssertEqual(RecognitionStats.classify(autoName: nil, userName: "Speaker A"), .added)
        XCTAssertEqual(RecognitionStats.classify(autoName: "", userName: "Speaker A"), .added)
    }

    func testClassifySkipped() {
        XCTAssertEqual(RecognitionStats.classify(autoName: "Speaker A", userName: nil), .skipped)
        XCTAssertEqual(RecognitionStats.classify(autoName: "Speaker A", userName: ""), .skipped)
        XCTAssertEqual(RecognitionStats.classify(autoName: "Speaker A", userName: "   "), .skipped)
        XCTAssertEqual(RecognitionStats.classify(autoName: nil, userName: nil), .skipped)
    }

    func testClassifyTrimsWhitespace() {
        XCTAssertEqual(
            RecognitionStats.classify(autoName: " Speaker A ", userName: "Speaker A"), .accepted,
        )
    }

    // MARK: - RecognitionTrack

    func testTrackFromLabel() {
        XCTAssertEqual(RecognitionTrack(label: "R_S1"), .app)
        XCTAssertEqual(RecognitionTrack(label: "M_S1"), .mic)
        XCTAssertEqual(RecognitionTrack(label: "S1"), .single)
    }

    // MARK: - aggregate

    func testAggregateBinsByAction() {
        let now = Date()
        let events: [RecognitionEvent] = [
            event(name: "a", action: .accepted, ts: now),
            event(name: "b", action: .accepted, ts: now),
            event(name: "c", action: .corrected, ts: now),
            event(name: "d", action: .added, ts: now),
        ]
        let agg = RecognitionStats.aggregate(events: events, from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        XCTAssertEqual(agg.total, 4)
        XCTAssertEqual(agg.counts[.accepted], 2)
        XCTAssertEqual(agg.counts[.corrected], 1)
        XCTAssertEqual(agg.counts[.added], 1)
        XCTAssertEqual(agg.acceptanceRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(agg.correctionRate, 0.25, accuracy: 1e-9)
    }

    func testAggregateRespectsTimeWindow() {
        let now = Date()
        let events: [RecognitionEvent] = [
            event(name: "old", action: .accepted, ts: now.addingTimeInterval(-3600)),
            event(name: "new", action: .accepted, ts: now),
        ]
        let agg = RecognitionStats.aggregate(events: events, from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
        XCTAssertEqual(agg.total, 1)
    }

    func testAggregateEmptyHasZeroRates() {
        let now = Date()
        let agg = RecognitionStats.aggregate(events: [], from: now.addingTimeInterval(-1), to: now)
        XCTAssertEqual(agg.total, 0)
        XCTAssertEqual(agg.acceptanceRate, 0)
        XCTAssertEqual(agg.correctionRate, 0)
    }

    // MARK: - JSONL round-trip via RecognitionStatsLog

    func testAppendAndLoadRoundTrip() async {
        let tmp = uniqueTempPath()
        let log = RecognitionStatsLog(path: tmp)
        let now = Date()
        let events: [RecognitionEvent] = [
            event(name: "Speaker A", action: .accepted, ts: now),
            event(name: "Speaker B", action: .corrected, ts: now),
        ]
        await log.append(events)

        let loaded = await log.loadRecent(within: 60, now: now)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.userName).sorted { ($0 ?? "") < ($1 ?? "") }, ["Speaker A", "Speaker B"])

        try? FileManager.default.removeItem(at: tmp)
    }

    func testAppendMultipleBatches() async {
        let tmp = uniqueTempPath()
        let log = RecognitionStatsLog(path: tmp)
        let now = Date()
        await log.append([event(name: "A", action: .accepted, ts: now)])
        await log.append([event(name: "B", action: .added, ts: now)])

        let loaded = await log.loadRecent(within: 60, now: now)
        XCTAssertEqual(loaded.count, 2)

        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoadRecentSkipsCorruptLines() async throws {
        let tmp = uniqueTempPath()
        let log = RecognitionStatsLog(path: tmp)
        let now = Date()
        await log.append([event(name: "Speaker A", action: .accepted, ts: now)])

        // Append a garbage line
        let handle = try FileHandle(forWritingTo: tmp)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        let loaded = await log.loadRecent(within: 60, now: now)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.userName, "Speaker A")

        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoadRecentFiltersByCutoff() async {
        let tmp = uniqueTempPath()
        let log = RecognitionStatsLog(path: tmp)
        let now = Date()
        await log.append([
            event(name: "old", action: .accepted, ts: now.addingTimeInterval(-3600)),
            event(name: "new", action: .accepted, ts: now),
        ])

        let loaded = await log.loadRecent(within: 60, now: now)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.userName, "new")

        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - buildEvents

    func testBuildEventsClassifiesAllActions() {
        let suggested = [
            "R_S1": "Speaker A", // accepted
            "R_S2": "Speaker B", // corrected
            "R_S3": "R_S3", // added (no auto)
            "M_S1": "Speaker C", // skipped (user clears)
        ]
        let userMapping = [
            "R_S1": "Speaker A",
            "R_S2": "Speaker D",
            "R_S3": "Speaker E",
            "M_S1": "",
        ]
        let events = RecognitionStats.buildEvents(
            suggested: suggested, userMapping: userMapping,
            topCandidates: [:],
            jobID: UUID(), meetingTitle: "Test",
        )
        let byLabel = Dictionary(uniqueKeysWithValues: events.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["R_S1"]?.action, .accepted)
        XCTAssertEqual(byLabel["R_S2"]?.action, .corrected)
        XCTAssertEqual(byLabel["R_S3"]?.action, .added)
        XCTAssertNil(byLabel["R_S3"].flatMap(\.autoName))
        XCTAssertEqual(byLabel["M_S1"]?.action, .skipped)
        XCTAssertNil(byLabel["M_S1"].flatMap(\.userName))
        XCTAssertEqual(byLabel["R_S1"]?.track, .app)
        XCTAssertEqual(byLabel["M_S1"]?.track, .mic)
    }

    func testBuildEventsDismissedWhenUserMappingNil() {
        let suggested = ["R_S1": "Speaker A", "R_S2": "R_S2"]
        let events = RecognitionStats.buildEvents(
            suggested: suggested, userMapping: nil,
            topCandidates: [:],
            jobID: UUID(), meetingTitle: "Test",
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.action == .dismissed })
        XCTAssertTrue(events.allSatisfy { $0.userName == nil })
        let s1 = events.first { $0.label == "R_S1" }
        XCTAssertEqual(s1?.autoName, "Speaker A")
        let s2 = events.first { $0.label == "R_S2" }
        XCTAssertNil(s2.flatMap(\.autoName))
    }

    // MARK: - Helpers

    private func event(
        name: String, action: RecognitionAction, ts: Date,
    ) -> RecognitionEvent {
        RecognitionEvent(
            ts: ts, jobID: UUID(), meetingTitle: "Test",
            track: .single, label: "S1",
            autoName: action == .added ? nil : name,
            userName: action == .skipped || action == .dismissed ? nil : name,
            action: action, topCandidates: nil,
        )
    }

    func testBuildEventsThreadsTopCandidates() {
        let suggested = ["R_S1": "Speaker A"]
        let userMapping = ["R_S1": "Speaker A"]
        let candidates = [
            "R_S1": [
                TopCandidate(name: "Speaker A", sample: 0.10, centroid: 0.22),
                TopCandidate(name: "Speaker B", sample: 0.40, centroid: nil),
            ],
        ]
        let events = RecognitionStats.buildEvents(
            suggested: suggested, userMapping: userMapping,
            topCandidates: candidates,
            jobID: UUID(), meetingTitle: "Test",
        )
        XCTAssertEqual(events.first?.topCandidates?.count, 2)
        XCTAssertEqual(events.first?.topCandidates?.first?.name, "Speaker A")
        let lastCentroid: Float? = events.first?.topCandidates?.last?.centroid
        XCTAssertNil(lastCentroid)
    }

    private func uniqueTempPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recognition_log_\(UUID().uuidString).jsonl")
    }
}
