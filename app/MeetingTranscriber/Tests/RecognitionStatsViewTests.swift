@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class RecognitionStatsViewTests: XCTestCase {
    func testViewRendersEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("recognition_log_\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let view = RecognitionStatsView(log: RecognitionStatsLog(path: tmp))
        XCTAssertNoThrow(try view.inspect())
    }

    func testViewLoadsAggregateFromLog() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("recognition_log_\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let log = RecognitionStatsLog(path: tmp)
        let now = Date()
        await log.append([
            RecognitionEvent(
                ts: now, jobID: UUID(), meetingTitle: "M",
                track: .single, label: "S0",
                autoName: "Speaker A", userName: "Speaker A",
                action: .accepted, topCandidates: nil,
            ),
            RecognitionEvent(
                ts: now, jobID: UUID(), meetingTitle: "M",
                track: .single, label: "S1",
                autoName: "Speaker A", userName: "Speaker B",
                action: .corrected, topCandidates: nil,
            ),
        ])

        let loaded = await log.loadRecent(within: 60, now: now)
        let agg = RecognitionStats.aggregate(
            events: loaded,
            from: now.addingTimeInterval(-60), to: now,
        )
        XCTAssertEqual(agg.total, 2)
        XCTAssertEqual(agg.acceptanceRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(agg.correctionRate, 0.5, accuracy: 1e-9)
    }
}
