@testable import MeetingTranscriber
import XCTest

/// Pins the on-disk format of the live transcript: one JSON object per line,
/// appended as captions finalize, owner-only, so an external agent can tail it.
@MainActor
final class LiveTranscriptFileTests: XCTestCase {
    /// A fresh folder path per test, removed when the test ends. Reserved, not created
    /// (`makeTempDirectory` would create it with default permissions), so the tests
    /// see the folder mode the code under test sets.
    private lazy var directory = makeTempFile(suffix: "-LiveTranscriptFileTests")

    private func lines(of url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"), "every event ends its line, so a tail never sees half an event")
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    func testOpenWritesStartEventInOwnerOnlyFile() throws {
        let file = try XCTUnwrap(LiveTranscriptFile.open(in: directory))

        XCTAssertEqual(file.url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(file.url.pathExtension, "jsonl")
        let events = try lines(of: file.url)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "start")
        XCTAssertEqual(events.first?["v"] as? Int, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "spoken meeting content must not be readable by other local users")
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
    }

    func testFinalSpeakerAndEndEventsAppendInOrder() throws {
        let file = try XCTUnwrap(LiveTranscriptFile.open(in: directory))

        file.appendFinal(sequence: 3, channel: .app, speaker: "Remote", text: "please create a \"ticket\"\nnow")
        file.appendSpeaker(sequence: 3, speaker: "Speaker B")
        file.appendEnd()

        let events = try lines(of: file.url)
        XCTAssertEqual(events.map { $0["type"] as? String }, ["start", "final", "speaker", "end"])
        let final = events[1]
        XCTAssertEqual(final["seq"] as? Int, 3)
        XCTAssertEqual(final["channel"] as? String, "app")
        XCTAssertEqual(final["speaker"] as? String, "Remote")
        XCTAssertEqual(final["text"] as? String, "please create a \"ticket\"\nnow", "quotes and newlines survive escaping")
        XCTAssertNotNil(final["at"] as? String)
        XCTAssertNotNil(final["offset"] as? Double)
        XCTAssertEqual(events[2]["seq"] as? Int, 3)
        XCTAssertEqual(events[2]["speaker"] as? String, "Speaker B")
    }

    func testNothingIsWrittenAfterEnd() throws {
        let file = try XCTUnwrap(LiveTranscriptFile.open(in: directory))

        file.appendEnd()
        file.appendSpeaker(sequence: 1, speaker: "Speaker A")
        file.appendFinal(sequence: 2, channel: .mic, speaker: "Me", text: "too late")

        XCTAssertEqual(try lines(of: file.url).map { $0["type"] as? String }, ["start", "end"], "a reader stops at end")
    }

    func testTwoFilesOpenedInTheSameSecondDoNotShareAPath() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = DateFormatter.filenameStamp("yyyyMMdd_HHmmss").string(from: now)
        let first = try XCTUnwrap(LiveTranscriptFile.open(in: directory, now: now))
        let second = try XCTUnwrap(LiveTranscriptFile.open(in: directory, now: now))

        XCTAssertEqual(first.url.lastPathComponent, "\(stamp)_live.jsonl")
        XCTAssertEqual(second.url.lastPathComponent, "\(stamp)-2_live.jsonl", "a quick stop and restart must not append to the last meeting's file")
    }

    /// `setAttributes` follows a link, so tightening a symlinked folder would change the
    /// mode of whatever it points to. The link is used as it is.
    func testASymlinkedFolderIsUsedWithoutChangingItsTarget() throws {
        let target = makeTempFile(suffix: "-LiveTranscriptLinkTarget")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)

        let file = try XCTUnwrap(LiveTranscriptFile.open(in: directory), "a symlinked folder still takes the file")

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755, "the link's target keeps its mode")
    }

    func testAnExistingFolderIsMadeOwnerOnly() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        _ = try XCTUnwrap(LiveTranscriptFile.open(in: directory))

        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700, "a folder left with a wider mode must not expose the new file's folder listing")
    }
}
