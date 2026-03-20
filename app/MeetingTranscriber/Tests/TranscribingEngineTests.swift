@testable import MeetingTranscriber
import XCTest

@MainActor
final class TranscribingEngineTests: XCTestCase {
    private func makeEngine() -> WhisperKitEngine {
        WhisperKitEngine()
    }

    // MARK: - Speaker Labels

    func testLabelsAppSegmentsAsRemote() {
        let appSegs = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
            TimestampedSegment(start: 5, end: 10, text: "World"),
        ]
        let result = makeEngine().mergeDualSourceSegments(appSegments: appSegs, micSegments: [])

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.speaker == "Remote" })
    }

    func testLabelsMicSegmentsWithDefaultMicLabel() {
        let micSegs = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
            TimestampedSegment(start: 5, end: 10, text: "World"),
        ]
        let result = makeEngine().mergeDualSourceSegments(appSegments: [], micSegments: micSegs)

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.speaker == "Me" })
    }

    func testCustomMicLabelIsApplied() {
        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "App")]
        let micSegs = [TimestampedSegment(start: 1, end: 6, text: "Mic")]

        let result = makeEngine().mergeDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micLabel: "Alice",
        )

        let micResult = result.first { $0.text == "Mic" }
        XCTAssertEqual(micResult?.speaker, "Alice")
    }

    // MARK: - Sorting

    func testSortsMergedResultByStartTimestamp() {
        let appSegs = [
            TimestampedSegment(start: 0, end: 3, text: "First"),
            TimestampedSegment(start: 10, end: 13, text: "Fourth"),
        ]
        let micSegs = [
            TimestampedSegment(start: 3, end: 6, text: "Second"),
            TimestampedSegment(start: 6, end: 9, text: "Third"),
        ]

        let result = makeEngine().mergeDualSourceSegments(appSegments: appSegs, micSegments: micSegs)

        XCTAssertEqual(result.map(\.text), ["First", "Second", "Third", "Fourth"])
        XCTAssertEqual(result.map(\.start), [0, 3, 6, 10])
    }

    func testInterleavedTimestampsMergeCorrectly() {
        let appSegs = [
            TimestampedSegment(start: 0, end: 3, text: "A1"),
            TimestampedSegment(start: 6, end: 9, text: "A2"),
        ]
        let micSegs = [
            TimestampedSegment(start: 3, end: 6, text: "M1"),
            TimestampedSegment(start: 9, end: 12, text: "M2"),
        ]

        let result = makeEngine().mergeDualSourceSegments(appSegments: appSegs, micSegments: micSegs)

        XCTAssertEqual(result.map(\.text), ["A1", "M1", "A2", "M2"])
        XCTAssertEqual(result.map(\.speaker), ["Remote", "Me", "Remote", "Me"])
    }

    // MARK: - Mic Delay

    func testAppliesMicDelayToMicSegments() throws {
        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "App")]
        let micSegs = [TimestampedSegment(start: 0, end: 5, text: "Mic")]

        let result = makeEngine().mergeDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micDelay: 3.0,
        )

        let micResult = try XCTUnwrap(result.first { $0.text == "Mic" })
        XCTAssertEqual(micResult.start, 3.0, accuracy: 0.001)
        XCTAssertEqual(micResult.end, 8.0, accuracy: 0.001)
    }

    func testMicDelayDoesNotAffectAppSegments() throws {
        let appSegs = [TimestampedSegment(start: 5, end: 10, text: "App")]
        let micSegs = [TimestampedSegment(start: 0, end: 5, text: "Mic")]

        let result = makeEngine().mergeDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micDelay: 2.0,
        )

        let appResult = try XCTUnwrap(result.first { $0.text == "App" })
        XCTAssertEqual(appResult.start, 5.0, accuracy: 0.001)
        XCTAssertEqual(appResult.end, 10.0, accuracy: 0.001)
    }

    func testZeroMicDelayDoesNotModifyTimestamps() {
        let micSegs = [TimestampedSegment(start: 3, end: 8, text: "Mic")]

        let result = makeEngine().mergeDualSourceSegments(
            appSegments: [], micSegments: micSegs, micDelay: 0,
        )

        XCTAssertEqual(result[0].start, 3.0, accuracy: 0.001)
        XCTAssertEqual(result[0].end, 8.0, accuracy: 0.001)
    }

    func testNegativeMicDelayShiftsBackward() throws {
        let appSegs = [TimestampedSegment(start: 5, end: 10, text: "App")]
        let micSegs = [TimestampedSegment(start: 7, end: 12, text: "Mic")]

        let result = makeEngine().mergeDualSourceSegments(
            appSegments: appSegs, micSegments: micSegs, micDelay: -2.0,
        )

        let micResult = try XCTUnwrap(result.first { $0.text == "Mic" })
        XCTAssertEqual(micResult.start, 5.0, accuracy: 0.001)
        XCTAssertEqual(micResult.end, 10.0, accuracy: 0.001)
    }

    // MARK: - Empty Inputs

    func testEmptyAppSegmentsReturnsOnlyMicSegments() {
        let micSegs = [
            TimestampedSegment(start: 0, end: 5, text: "Mic1"),
            TimestampedSegment(start: 5, end: 10, text: "Mic2"),
        ]

        let result = makeEngine().mergeDualSourceSegments(appSegments: [], micSegments: micSegs)

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.speaker == "Me" })
        XCTAssertEqual(result.map(\.text), ["Mic1", "Mic2"])
    }

    func testEmptyMicSegmentsReturnsOnlyAppSegments() {
        let appSegs = [
            TimestampedSegment(start: 0, end: 5, text: "App1"),
            TimestampedSegment(start: 5, end: 10, text: "App2"),
        ]

        let result = makeEngine().mergeDualSourceSegments(appSegments: appSegs, micSegments: [])

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.speaker == "Remote" })
        XCTAssertEqual(result.map(\.text), ["App1", "App2"])
    }

    func testBothEmptyReturnsEmptyResult() {
        let result = makeEngine().mergeDualSourceSegments(appSegments: [], micSegments: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Text Preservation

    func testPreservesSegmentTextThroughMerge() {
        let appSegs = [TimestampedSegment(start: 0, end: 5, text: "Hello from the app side")]
        let micSegs = [TimestampedSegment(start: 2, end: 7, text: "Hello from the mic side")]

        let result = makeEngine().mergeDualSourceSegments(appSegments: appSegs, micSegments: micSegs)

        XCTAssertEqual(result[0].text, "Hello from the app side")
        XCTAssertEqual(result[1].text, "Hello from the mic side")
    }

    func testPreservesTextWithMicDelay() {
        let micSegs = [TimestampedSegment(start: 0, end: 5, text: "Delayed mic text")]

        let result = makeEngine().mergeDualSourceSegments(
            appSegments: [], micSegments: micSegs, micDelay: 10.0,
        )

        XCTAssertEqual(result[0].text, "Delayed mic text")
    }
}
