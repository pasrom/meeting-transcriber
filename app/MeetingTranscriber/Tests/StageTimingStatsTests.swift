@testable import MeetingTranscriber
import XCTest

final class StageTimingStatsTests: XCTestCase {
    private func event(
        _ stage: StageKind, wall: Double, audio: Double, ts: Date = Date(),
        engine: String? = "parakeet", mode: String? = nil,
    ) -> StageTimingEvent {
        StageTimingEvent(
            ts: ts, jobID: UUID(), stage: stage,
            wallClockSeconds: wall, audioSeconds: audio,
            engine: engine, diarizerMode: mode ?? (stage == .diarizing ? "offline" : nil),
        )
    }

    // MARK: - Per-config aggregation

    func testAggregateByConfigSeparatesEngineAndMode() {
        let events = [
            event(.diarizing, wall: 600, audio: 6000, engine: "Parakeet", mode: "offline"),
            event(.diarizing, wall: 1200, audio: 6000, engine: "Parakeet", mode: "sortformer"),
            event(.diarizing, wall: 300, audio: 6000, engine: "WhisperKit", mode: "offline"),
        ]
        let agg = StageTimingStats.aggregateByConfig(events: events)
        XCTAssertEqual(agg.count, 3, "three distinct (stage, engine, mode) configs")
        XCTAssertEqual(
            agg[StageConfig(stage: .diarizing, engine: "Parakeet", diarizerMode: "offline")]?
                .avgWallClockSeconds ?? 0, 600, accuracy: 0.001,
        )
        XCTAssertEqual(
            agg[StageConfig(stage: .diarizing, engine: "Parakeet", diarizerMode: "sortformer")]?
                .avgWallClockSeconds ?? 0, 1200, accuracy: 0.001,
        )
    }

    // MARK: - Slower-than-usual decision

    func testIsSlowerThanUsualNeedsBothRatioAndAbsoluteFloor() {
        // Ratio (>1.5x) and overrun (>=30s) both met.
        XCTAssertTrue(StageTimingStats.isSlowerThanUsual(elapsed: 80, average: 40))
        // Floor is inclusive at exactly +30s (still >1.5x: 70 > 60).
        XCTAssertTrue(StageTimingStats.isSlowerThanUsual(elapsed: 70, average: 40))
        // Ratio met but overrun 29s < 30s floor → not flagged (tiny-stage noise).
        XCTAssertFalse(StageTimingStats.isSlowerThanUsual(elapsed: 69, average: 40))
        // Overrun big but ratio not met (1.25x).
        XCTAssertFalse(StageTimingStats.isSlowerThanUsual(elapsed: 500, average: 400))
        // Exactly 1.5x is not "more than" 1.5x.
        XCTAssertFalse(StageTimingStats.isSlowerThanUsual(elapsed: 60, average: 40))
        // No norm yet.
        XCTAssertFalse(StageTimingStats.isSlowerThanUsual(elapsed: 100, average: 0))
    }

    // MARK: - Aggregation

    func testAggregateGroupsByStageAndAveragesWallClock() {
        let events = [
            event(.diarizing, wall: 600, audio: 6000),
            event(.diarizing, wall: 400, audio: 4000),
            event(.transcribing, wall: 120, audio: 6000),
        ]
        let agg = StageTimingStats.aggregate(events: events)

        XCTAssertEqual(agg[.diarizing]?.count, 2)
        XCTAssertEqual(agg[.diarizing]?.avgWallClockSeconds ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(agg[.transcribing]?.count, 1)
        XCTAssertEqual(agg[.transcribing]?.avgWallClockSeconds ?? 0, 120, accuracy: 0.001)
    }

    func testAvgRTFIsRatioOfTotalsNotMeanOfRatios() {
        // Throughput across the whole corpus: sum(wall)/sum(audio), so a long
        // meeting weighs more than a short one. (600+400)/(6000+4000) = 0.1.
        let events = [
            event(.diarizing, wall: 600, audio: 6000),
            event(.diarizing, wall: 400, audio: 4000),
        ]
        let agg = StageTimingStats.aggregate(events: events)
        XCTAssertEqual(agg[.diarizing]?.avgRTF ?? -1, 0.1, accuracy: 0.0001)
    }

    func testAvgRTFNilWhenNoPositiveAudio() {
        // A stage whose events all report 0s of audio can't be normalised.
        let events = [event(.transcribing, wall: 30, audio: 0)]
        let agg = StageTimingStats.aggregate(events: events)
        XCTAssertEqual(agg[.transcribing]?.count, 1)
        XCTAssertNil(agg[.transcribing]?.avgRTF)
    }

    func testAvgRTFSkipsZeroAudioEventsButKeepsCount() {
        // A zero-audio outlier must not poison the RTF (no divide-by-zero, not
        // counted in the throughput) yet still counts toward avgWallClock/count.
        let events = [
            event(.diarizing, wall: 500, audio: 5000),
            event(.diarizing, wall: 999, audio: 0),
        ]
        let agg = StageTimingStats.aggregate(events: events)
        XCTAssertEqual(agg[.diarizing]?.count, 2)
        XCTAssertEqual(agg[.diarizing]?.avgRTF ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(agg[.diarizing]?.avgWallClockSeconds ?? 0, 749.5, accuracy: 0.001)
    }

    func testAggregateEmptyForNoEvents() {
        XCTAssertTrue(StageTimingStats.aggregate(events: []).isEmpty)
    }

    // MARK: - JobState → StageKind mapping

    func testStageKindMapsOnlyTimedStates() {
        XCTAssertEqual(StageKind(jobState: .transcribing), .transcribing)
        XCTAssertEqual(StageKind(jobState: .diarizing), .diarizing)
        XCTAssertEqual(StageKind(jobState: .generatingProtocol), .generatingProtocol)
    }

    func testStageKindExcludesNamingAndTerminalStates() {
        // The naming wait is human-paced and must never be attributed to a
        // stage; waiting/done/error aren't compute either.
        XCTAssertNil(StageKind(jobState: .speakerNamingPending))
        XCTAssertNil(StageKind(jobState: .waiting))
        XCTAssertNil(StageKind(jobState: .done))
        XCTAssertNil(StageKind(jobState: .error))
    }

    // MARK: - Log round-trip + window filtering

    func testLogAppendThenLoadRecentRoundTrips() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage_timing_test_\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let log = StageTimingLog(path: tmp)

        // Whole-second timestamp: the log encodes ts as ISO-8601 (second
        // precision), so a fractional `now` would not round-trip Equatable.
        let now = Date(timeIntervalSince1970: 1_781_500_000)
        let fresh = event(.diarizing, wall: 300, audio: 3000, ts: now)
        let stale = event(.diarizing, wall: 300, audio: 3000, ts: now.addingTimeInterval(-100 * 86400))
        await log.append([fresh])
        await log.append([stale])

        let loaded = await log.loadRecent(within: 30 * 86400, now: now)
        XCTAssertEqual(loaded.count, 1, "only the in-window event should load")
        XCTAssertEqual(loaded.first, fresh)
    }
}
