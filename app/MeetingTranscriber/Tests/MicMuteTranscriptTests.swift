// swiftlint:disable single_test_class
import AudioTapLib
@testable import MeetingTranscriber
import XCTest

final class MicMuteTranscriptTests: XCTestCase {
    private let muted = [MicMuteInterval(start: 10, end: 20)]

    func testMarkerSitsAmongTheLinesByTime() {
        let text = [
            TimestampedSegment(start: 5, end: 6, text: "before"),
            TimestampedSegment(start: 25, end: 26, text: "after"),
        ].transcriptText(note: nil, micMuted: muted)
        XCTAssertEqual(text, "[00:05] before\n[Mic muted 00:10–00:20]\n[00:25] after")
    }

    func testMarkerSortsAheadOfALineAtTheSameMoment() {
        let text = [TimestampedSegment(start: 10, end: 11, text: "remote")]
            .transcriptText(note: nil, micMuted: muted)
        XCTAssertEqual(text, "[Mic muted 00:10–00:20]\n[00:10] remote")
    }

    func testNoteStaysAboveTheMarkers() {
        let text = [TimestampedSegment]().transcriptText(note: "[note]", micMuted: muted)
        XCTAssertEqual(text, "[note]\n\n[Mic muted 00:10–00:20]")
    }

    func testTextInsideAMuteIsDropped() {
        let kept = [TimestampedSegment(start: 12, end: 15, text: "hallucinated")].removingMuted(muted)
        XCTAssertTrue(kept.isEmpty)
    }

    func testSentenceMostlyBeforeTheMuteIsKept() {
        let kept = [TimestampedSegment(start: 5, end: 11, text: "recorded")].removingMuted(muted)
        XCTAssertEqual(kept.count, 1)
    }

    func testNoIntervalsKeepEverything() {
        let kept = [TimestampedSegment(start: 12, end: 15, text: "said")].removingMuted([])
        XCTAssertEqual(kept.count, 1)
    }
}

final class MicMuteViabilityTests: XCTestCase {
    func testMutedThroughoutIsAppOnlyWithoutAWarning() {
        let viability = DualTrackViability.resolve(
            appFrames: 16000, micFrames: 16000, minimumFrames: 4800, micMutedFrames: 15000,
        )
        XCTAssertEqual(viability, .appOnlyMicMuted)
        XCTAssertNil(viability.droppedTrackWarning)
        XCTAssertTrue(viability.carriesAppAudio)
        XCTAssertFalse(viability.carriesMicAudio)
        XCTAssertEqual(viability.transcriptNote?.contains("muted"), true)
    }

    func testPartialMuteStaysBoth() {
        let viability = DualTrackViability.resolve(
            appFrames: 16000, micFrames: 16000, minimumFrames: 4800, micMutedFrames: 8000,
        )
        XCTAssertEqual(viability, .both)
    }

    func testEmptyMicIsStillAFault() {
        let viability = DualTrackViability.resolve(
            appFrames: 16000, micFrames: 0, minimumFrames: 4800, micMutedFrames: 0,
        )
        XCTAssertEqual(viability, .appOnly)
    }
}

final class MicMuteLogTests: XCTestCase {
    private var dir = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    func testMuteOpenAtACrashRunsToTheEndOfTheTrack() throws {
        let track = dir.appendingPathComponent("s_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0, count: 32000), sampleRate: 16000, url: track)
        var timeline = MicMuteTimeline()
        timeline.setMuted(true)
        MicMuteLog.write(timeline, stem: "s", in: dir)

        let intervals = MicMuteLog.recoveredIntervals(stem: "s", in: dir, micTrack: track)
        XCTAssertEqual(intervals, [MicMuteInterval(start: 0, end: 2)])
        MicMuteLog.remove(stem: "s", in: dir)
        XCTAssertTrue(MicMuteLog.recoveredIntervals(stem: "s", in: dir, micTrack: track).isEmpty)
    }

    func testRecordingWithNoMuteRecoversNoIntervals() {
        let track = dir.appendingPathComponent("s_mic.wav")
        XCTAssertTrue(MicMuteLog.recoveredIntervals(stem: "s", in: dir, micTrack: track).isEmpty)
    }

    func testALogWithNoMicTrackRecoversNoIntervals() {
        var timeline = MicMuteTimeline()
        timeline.setMuted(true)
        MicMuteLog.write(timeline, stem: "s", in: dir)

        XCTAssertTrue(MicMuteLog.recoveredIntervals(stem: "s", in: dir, micTrack: nil).isEmpty)
    }
}

final class MicMuteSnapshotTests: XCTestCase {
    func testJobFromASnapshotBeforeTheFieldDecodes() throws {
        let job = PipelineJob(
            meetingTitle: "t", appName: "a", mixPath: nil, appPath: nil, micPath: nil, micDelay: 2,
            micMuteIntervals: [MicMuteInterval(start: 1, end: 3)],
        )
        XCTAssertEqual(job.micMuteSpansOnTranscript, [MicMuteInterval(start: 3, end: 5)])

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any],
        )
        object.removeValue(forKey: "micMuteIntervals")
        let old = try JSONDecoder().decode(
            PipelineJob.self, from: JSONSerialization.data(withJSONObject: object),
        )
        XCTAssertTrue(old.micMuteSpansOnTranscript.isEmpty)
    }
}

/// Mute times read from disk, a reimported sidecar among them, reach `Int`
/// conversions that trap, and an overlap would count twice.
final class MicMuteIntervalSanitizingTests: XCTestCase {
    func testHugeAndNonFiniteTimesAreClippedOrDropped() {
        let intervals = [
            MicMuteInterval(start: 0, end: 1e100),
            MicMuteInterval(start: .nan, end: 5),
            MicMuteInterval(start: 3, end: .infinity),
        ].sanitized
        XCTAssertEqual(intervals, [MicMuteInterval(start: 0, end: MicMuteInterval.maxSeconds)])
        XCTAssertGreaterThan(intervals.mutedFrames(rate: 48000), 0, "converts without trapping")
        XCTAssertFalse(intervals[0].transcriptMarker.isEmpty)
    }

    func testOverlapsMergeAndEmptyOrBackwardsOnesAreDropped() {
        let intervals = [
            MicMuteInterval(start: 8, end: 12),
            MicMuteInterval(start: 2, end: 4),
            MicMuteInterval(start: 3, end: 9),
            MicMuteInterval(start: 20, end: 20),
            MicMuteInterval(start: 30, end: 25),
            MicMuteInterval(start: -5, end: 1),
        ].sanitized
        XCTAssertEqual(intervals, [MicMuteInterval(start: 0, end: 1), MicMuteInterval(start: 2, end: 12)])
    }

    func testAJobSanitizesWhatItIsGiven() {
        let job = PipelineJob(
            meetingTitle: "t", appName: "Microphone", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
            micMuteIntervals: [MicMuteInterval(start: 0, end: 1e100)],
        )
        XCTAssertEqual(job.micMuteSpansOnTranscript, [MicMuteInterval(start: 0, end: MicMuteInterval.maxSeconds)])
    }
}
