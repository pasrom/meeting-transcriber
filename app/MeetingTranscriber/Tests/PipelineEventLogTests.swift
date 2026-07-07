@testable import MeetingTranscriber
import XCTest

// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`,
// so there's no explicit `tearDown` to balance `setUp`.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PipelineEventLogTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_event_log_test")
    }

    /// One decoded log entry. Mirrors the append entry's `[String: String]`
    /// shape so tests can assert on the exact fields.
    private struct Entry: Decodable {
        let timestamp: String
        // swiftlint:disable:next identifier_name
        let job_id: String
        let event: String
        let from: String
        let to: String
    }

    private func decodeLines(_ url: URL) throws -> [Entry] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
    }

    // MARK: - append

    func testFirstAppendCreatesDecodableLine() throws {
        let log = PipelineEventLog(logDir: tmpDir)
        let jobID = UUID()
        log.append(jobID: jobID, event: "enqueued", from: nil, to: .waiting)

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path.path))

        let entries = try decodeLines(log.path)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.job_id, jobID.uuidString)
        XCTAssertEqual(entry.event, "enqueued")
        // nil `from` serializes as "-".
        XCTAssertEqual(entry.from, "-")
        XCTAssertEqual(entry.to, JobState.waiting.rawValue)
        XCTAssertFalse(entry.timestamp.isEmpty)
    }

    func testFirstAppendSetsOwnerOnlyPermissions() throws {
        let log = PipelineEventLog(logDir: tmpDir)
        log.append(jobID: UUID(), event: "enqueued", from: nil, to: .waiting)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: log.path.path)[.posixPermissions] as? Int,
        )
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testSecondAppendAppendsSecondLine() throws {
        let log = PipelineEventLog(logDir: tmpDir)
        let jobID = UUID()
        log.append(jobID: jobID, event: "enqueued", from: nil, to: .waiting)
        log.append(jobID: jobID, event: "state_change", from: .waiting, to: .transcribing)

        let entries = try decodeLines(log.path)
        XCTAssertEqual(entries.count, 2)

        // Both lines are valid JSON and preserve their fields, including a
        // real (non-nil) `from` on the transition.
        XCTAssertEqual(entries[0].event, "enqueued")
        XCTAssertEqual(entries[0].from, "-")
        XCTAssertEqual(entries[0].to, JobState.waiting.rawValue)
        XCTAssertEqual(entries[1].event, "state_change")
        XCTAssertEqual(entries[1].from, JobState.waiting.rawValue)
        XCTAssertEqual(entries[1].to, JobState.transcribing.rawValue)
    }

    func testAppendCreatesMissingLogDir() throws {
        // Point at a not-yet-existing subdirectory: append must self-ensure it.
        let nestedDir = tmpDir.appendingPathComponent("nested/logs")
        let log = PipelineEventLog(logDir: nestedDir)
        log.append(jobID: UUID(), event: "recovered", from: nil, to: .waiting)

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path.path))
        XCTAssertEqual(try decodeLines(log.path).count, 1)
    }
}
