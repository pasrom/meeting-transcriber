@testable import MeetingTranscriber
import XCTest

/// The ends a quit waits for, and the `end` the exit writes for what is left.
@MainActor
final class LiveTranscriptEndsTests: XCTestCase {
    private lazy var directory = makeTempFile(suffix: "-LiveTranscriptEnds")

    private func types(in file: LiveTranscriptFile) throws -> [String?] {
        try String(contentsOf: file.url, encoding: .utf8).split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])["type"] as? String
        }
    }

    func testAnEndIsHeldUntilItsEventsLanded() async throws {
        let ends = LiveTranscriptEnds()
        let file = try XCTUnwrap(LiveTranscriptFile.open(in: directory))
        file.eventsInFlight.enter()

        ends.end(file, waitingUpTo: .seconds(30))
        XCTAssertFalse(ends.isEmpty, "a quit must see the end still to come")
        file.appendFinal(sequence: 1, channel: .mic, speaker: "Me", text: "last words")
        file.eventsInFlight.leave()
        await ends.waitForAll()

        XCTAssertTrue(ends.isEmpty)
        XCTAssertEqual(try types(in: file), ["start", "final", "end"])
    }

    func testEndAllNowWritesTheEndOfAFileStillWaiting() throws {
        let ends = LiveTranscriptEnds()
        let file = try XCTUnwrap(LiveTranscriptFile.open(in: directory))
        file.eventsInFlight.enter() // a match that never returns

        ends.end(file, waitingUpTo: .seconds(30))
        ends.endAllNow()

        XCTAssertEqual(try types(in: file), ["start", "end"], "written at once, before the process exits")
    }
}
