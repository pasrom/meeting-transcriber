@testable import MeetingTranscriber
import XCTest

final class StreamingCaptionSplitterTests: XCTestCase {
    func testContinuousCumulativeTranscriptSplitsWithoutRepeatingOrDroppingWords() {
        var splitter = StreamingCaptionSplitter(maxWords: 3)
        let first = splitter.update("one two three four five six seven", audioTime: 1)
        XCTAssertEqual(first.finals, ["one two three", "four five six"])
        XCTAssertEqual(first.hypothesis, "seven")
        let next = splitter.update("one two three four five six seven eight", audioTime: 1.1)
        XCTAssertTrue(next.finals.isEmpty)
        XCTAssertEqual(next.hypothesis, "seven eight")
        let end = splitter.update("one two three four five six seven eight", audioTime: 1.2, finalize: true)
        XCTAssertEqual(end.finals, ["seven eight"])
        XCTAssertEqual(end.hypothesis, "")
        XCTAssertTrue(splitter.update("one two three four five six seven eight", audioTime: 2).finals.isEmpty)
    }

    func testPauseUsesAudioTimeAndRestartsWhenTextChanges() {
        var splitter = StreamingCaptionSplitter(pauseSeconds: 0.7)
        XCTAssertTrue(splitter.update("hello", audioTime: 1).finals.isEmpty)
        XCTAssertTrue(splitter.update("hello", audioTime: 1.6).finals.isEmpty)
        XCTAssertTrue(splitter.update("hello world", audioTime: 1.65).finals.isEmpty)
        XCTAssertTrue(splitter.update("hello world", audioTime: 2.3).finals.isEmpty)
        XCTAssertEqual(splitter.update("hello world", audioTime: 2.36).finals, ["hello world"])
        XCTAssertTrue(splitter.update("hello world", audioTime: 3).finals.isEmpty)
        XCTAssertEqual(splitter.update("hello world again", audioTime: 3.1).hypothesis, "again")
    }

    func testWaitsForWordBoundaryBeforeSplittingGrowingToken() {
        var splitter = StreamingCaptionSplitter(maxWords: 3)
        XCTAssertTrue(splitter.update("one two th", audioTime: 1).finals.isEmpty)
        XCTAssertTrue(splitter.update("one two three", audioTime: 1.1).finals.isEmpty)
        let update = splitter.update("one two three four", audioTime: 1.2)
        XCTAssertEqual(update.finals, ["one two three"])
        XCTAssertEqual(update.hypothesis, "four")
    }

    func testWhitespaceUnicodeAndReset() {
        var splitter = StreamingCaptionSplitter(maxWords: 2)
        let update = splitter.update("  café\n世界\tnew", audioTime: 1)
        XCTAssertEqual(update.finals, ["café\n世界"])
        XCTAssertEqual(update.hypothesis, "new")
        splitter.reset()
        let fresh = splitter.update("fresh text", audioTime: 0, finalize: true)
        XCTAssertEqual(fresh.finals, ["fresh text"])
        XCTAssertEqual(fresh.hypothesis, "")
    }
}
