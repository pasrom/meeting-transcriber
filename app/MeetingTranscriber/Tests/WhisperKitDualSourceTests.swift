import XCTest

@testable import MeetingTranscriber

final class TimestampedSegmentTests: XCTestCase {

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

        let merged = WhisperKitEngine.mergeSegments(a, b)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged[0].text, "First")
        XCTAssertEqual(merged[1].text, "Second")
        XCTAssertEqual(merged[2].text, "Third")
        XCTAssertEqual(merged[3].text, "Fourth")
    }

    func testMergeSegmentsEmptyA() {
        let b = [TimestampedSegment(start: 0, end: 5, text: "Only")]
        let merged = WhisperKitEngine.mergeSegments([], b)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "Only")
    }

    func testMergeSegmentsEmptyB() {
        let a = [TimestampedSegment(start: 0, end: 5, text: "Only")]
        let merged = WhisperKitEngine.mergeSegments(a, [])
        XCTAssertEqual(merged.count, 1)
    }

    func testMergeSegmentsBothEmpty() {
        let merged = WhisperKitEngine.mergeSegments([], [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergeSegmentsPreservesSpeakers() {
        var a = [TimestampedSegment(start: 0, end: 5, text: "App")]
        a[0].speaker = "Remote"

        var b = [TimestampedSegment(start: 2, end: 7, text: "Mic")]
        b[0].speaker = "Me"

        let merged = WhisperKitEngine.mergeSegments(a, b)
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
        for i in appSegs.indices { appSegs[i].speaker = "Remote" }
        for i in micSegs.indices { micSegs[i].speaker = "Me" }

        let merged = WhisperKitEngine.mergeSegments(appSegs, micSegs)
        XCTAssertEqual(merged.map(\.speaker), ["Remote", "Me", "Remote", "Me"])
        XCTAssertEqual(merged.map(\.text), ["A1", "M1", "A2", "M2"])
    }

    // MARK: - Formatted Output

    func testMergedFormattedOutput() {
        var seg1 = TimestampedSegment(start: 0, end: 5, text: "Hello")
        seg1.speaker = "Remote"
        var seg2 = TimestampedSegment(start: 5, end: 10, text: "Hi there")
        seg2.speaker = "Me"

        let merged = WhisperKitEngine.mergeSegments([seg1], [seg2])
        let output = merged.map(\.formattedLine).joined(separator: "\n")
        XCTAssertEqual(output, "[00:00] Remote: Hello\n[00:05] Me: Hi there")
    }
}
