@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class RecognitionStatsViewTests: XCTestCase {
    func testViewRendersEmpty() throws {
        let tmp = makeTempFile(suffix: ".jsonl")

        let view = RecognitionStatsView(log: RecognitionStatsLog(path: tmp))
        XCTAssertNoThrow(try view.inspect())
    }
}
