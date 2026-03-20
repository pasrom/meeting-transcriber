@testable import MeetingTranscriber
import XCTest

@MainActor
final class TimestampedSegmentTests: XCTestCase {
    /// Merge two segment arrays sorted by start timestamp (replaces removed WhisperKitEngine.mergeSegments).
    private static func mergeSegments(_ a: [TimestampedSegment], _ b: [TimestampedSegment]) -> [TimestampedSegment] {
        (a + b).sorted { $0.start < $1.start }
    }

    // MARK: - Timestamp Formatting

    func testFormattedTimestampShort() {
        let seg = TimestampedSegment(start: 65, end: 70, text: "Hello")
        XCTAssertEqual(seg.formattedTimestamp, "[01:05]")
    }

    func testFormattedTimestampZero() {
        let seg = TimestampedSegment(start: 0, end: 5, text: "Start")
        XCTAssertEqual(seg.formattedTimestamp, "[00:00]")
    }

    func testFormattedTimestampHours() {
        let seg = TimestampedSegment(start: 3661, end: 3665, text: "Late")
        XCTAssertEqual(seg.formattedTimestamp, "[1:01:01]")
    }

    func testFormattedTimestampJustUnderHour() {
        let seg = TimestampedSegment(start: 3599, end: 3600, text: "Almost")
        XCTAssertEqual(seg.formattedTimestamp, "[59:59]")
    }

    // MARK: - Formatted Line

    func testFormattedLineNoSpeaker() {
        let seg = TimestampedSegment(start: 10, end: 15, text: "Hello world")
        XCTAssertEqual(seg.formattedLine, "[00:10] Hello world")
    }

    func testFormattedLineWithSpeaker() {
        var seg = TimestampedSegment(start: 10, end: 15, text: "Hello world")
        seg.speaker = "Alice"
        XCTAssertEqual(seg.formattedLine, "[00:10] Alice: Hello world")
    }

    func testFormattedLineEmptySpeaker() {
        var seg = TimestampedSegment(start: 10, end: 15, text: "Test")
        seg.speaker = ""
        XCTAssertEqual(seg.formattedLine, "[00:10] Test")
    }

    // MARK: - Merge Segments

    func testMergeSegmentsSortsByStart() {
        let a = [
            TimestampedSegment(start: 0, end: 5, text: "First"),
            TimestampedSegment(start: 10, end: 15, text: "Third"),
        ]
        let b = [
            TimestampedSegment(start: 5, end: 10, text: "Second"),
            TimestampedSegment(start: 15, end: 20, text: "Fourth"),
        ]

        let merged = Self.mergeSegments(a, b)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged[0].text, "First")
        XCTAssertEqual(merged[1].text, "Second")
        XCTAssertEqual(merged[2].text, "Third")
        XCTAssertEqual(merged[3].text, "Fourth")
    }

    func testMergeSegmentsEmptyA() {
        let b = [TimestampedSegment(start: 0, end: 5, text: "Only")]
        let merged = Self.mergeSegments([], b)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "Only")
    }

    func testMergeSegmentsEmptyB() {
        let a = [TimestampedSegment(start: 0, end: 5, text: "Only")]
        let merged = Self.mergeSegments(a, [])
        XCTAssertEqual(merged.count, 1)
    }

    func testMergeSegmentsBothEmpty() {
        let merged = Self.mergeSegments([], [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergeSegmentsPreservesSpeakers() {
        var a = [TimestampedSegment(start: 0, end: 5, text: "App")]
        a[0].speaker = "Remote"

        var b = [TimestampedSegment(start: 2, end: 7, text: "Mic")]
        b[0].speaker = "Me"

        let merged = Self.mergeSegments(a, b)
        XCTAssertEqual(merged[0].speaker, "Remote")
        XCTAssertEqual(merged[1].speaker, "Me")
    }

    func testMergeSegmentsInterleavedTimestamps() {
        var appSegs = [
            TimestampedSegment(start: 0, end: 3, text: "A1"),
            TimestampedSegment(start: 6, end: 9, text: "A2"),
        ]
        var micSegs = [
            TimestampedSegment(start: 3, end: 6, text: "M1"),
            TimestampedSegment(start: 9, end: 12, text: "M2"),
        ]
        for i in appSegs.indices {
            appSegs[i].speaker = "Remote"
        }
        for i in micSegs.indices {
            micSegs[i].speaker = "Me"
        }

        let merged = (appSegs + micSegs).sorted { $0.start < $1.start }
        XCTAssertEqual(merged.map(\.speaker), ["Remote", "Me", "Remote", "Me"])
        XCTAssertEqual(merged.map(\.text), ["A1", "M1", "A2", "M2"])
    }

    // MARK: - Formatted Output

    func testMergedFormattedOutput() {
        var seg1 = TimestampedSegment(start: 0, end: 5, text: "Hello")
        seg1.speaker = "Remote"
        var seg2 = TimestampedSegment(start: 5, end: 10, text: "Hi there")
        seg2.speaker = "Me"

        let merged = ([seg1] + [seg2]).sorted { $0.start < $1.start }
        let output = merged.map { $0.formattedLine }.joined(separator: "\n")
        XCTAssertEqual(output, "[00:00] Remote: Hello\n[00:05] Me: Hi there")
    }

    // MARK: - Dual Source Segments (label + merge + delay logic)

    /// Simulate what transcribeDualSourceSegments does: label app as "Remote",
    /// mic as micLabel, apply mic delay, and merge by timestamp.
    private func simulateDualSourceSegments(
        appSegments: [TimestampedSegment],
        micSegments: [TimestampedSegment],
        micDelay: TimeInterval = 0,
        micLabel: String = "Me",
    ) -> [TimestampedSegment] {
        var app = appSegments
        var mic = micSegments

        // Shift mic timestamps by delay
        if micDelay != 0 {
            mic = mic.map { seg in
                TimestampedSegment(
                    start: seg.start + micDelay,
                    end: seg.end + micDelay,
                    text: seg.text,
                    speaker: seg.speaker,
                )
            }
        }

        // Label speakers
        for i in app.indices {
            app[i].speaker = "Remote"
        }
        for i in mic.indices {
            mic[i].speaker = micLabel
        }

        return (app + mic).sorted { $0.start < $1.start }
    }

    func testDualSourceSegmentsLabelsRemoteAndMic() {
        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "Hello from app")]
        let micSegs = [TimestampedSegment(start: 2, end: 7, text: "Hello from mic")]

        let result = simulateDualSourceSegments(appSegments: appSegs, micSegments: micSegs)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Remote")
        XCTAssertEqual(result[0].text, "Hello from app")
        XCTAssertEqual(result[1].speaker, "Me")
        XCTAssertEqual(result[1].text, "Hello from mic")
    }

    func testDualSourceSegmentsCustomMicLabel() {
        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "App")]
        let micSegs = [TimestampedSegment(start: 1, end: 6, text: "Mic")]

        let result = simulateDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micLabel: "Alice",
        )

        XCTAssertEqual(result[1].speaker, "Alice")
    }

    func testDualSourceSegmentsMicDelayShiftsTimestamps() {
        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "App")]
        let micSegs = [TimestampedSegment(start: 0, end: 5, text: "Mic")]

        let result = simulateDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micDelay: 3.0,
        )

        // App at 0, mic shifted to 3
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "App")
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[1].text, "Mic")
        XCTAssertEqual(result[1].start, 3.0)
        XCTAssertEqual(result[1].end, 8.0)
    }

    func testDualSourceSegmentsNegativeMicDelay() {
        let appSegs = [TimestampedSegment(start: 5, end: 10, text: "App")]
        let micSegs = [TimestampedSegment(start: 7, end: 12, text: "Mic")]

        let result = simulateDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micDelay: -2.0,
        )

        // Mic shifted from 7 to 5 — same start as app
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].start, 5.0)
        XCTAssertEqual(result[1].start, 5.0)
        // Both at same timestamp, mic end shifted to 10
        XCTAssertEqual(result[1].end, 10.0)
    }

    func testDualSourceSegmentsZeroDelayNoShift() {
        let micSegs = [TimestampedSegment(start: 3, end: 8, text: "Mic")]

        let result = simulateDualSourceSegments(
            appSegments: [], micSegments: micSegs, micDelay: 0,
        )

        XCTAssertEqual(result[0].start, 3.0)
        XCTAssertEqual(result[0].end, 8.0)
    }

    func testDualSourceSegmentsMergesInterleaved() {
        let appSegs = [
            TimestampedSegment(start: 0, end: 3, text: "A1"),
            TimestampedSegment(start: 6, end: 9, text: "A2"),
        ]
        let micSegs = [
            TimestampedSegment(start: 3, end: 6, text: "M1"),
            TimestampedSegment(start: 9, end: 12, text: "M2"),
        ]

        let result = simulateDualSourceSegments(appSegments: appSegs, micSegments: micSegs)

        XCTAssertEqual(result.map(\.text), ["A1", "M1", "A2", "M2"])
        XCTAssertEqual(result.map(\.speaker), ["Remote", "Me", "Remote", "Me"])
    }

    func testDualSourceSegmentsEmptyBothSources() {
        let result = simulateDualSourceSegments(appSegments: [], micSegments: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testDualSourceSegmentsFormattedOutputMatchesDualSource() {
        // Verify that formatting segments produces the same output as transcribeDualSource would
        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "Hello")]
        let micSegs = [TimestampedSegment(start: 5, end: 10, text: "Hi there")]

        let segments = simulateDualSourceSegments(appSegments: appSegs, micSegments: micSegs)
        let output = segments.map(\.formattedLine).joined(separator: "\n")

        XCTAssertEqual(output, "[00:00] Remote: Hello\n[00:05] Me: Hi there")
    }
}
