@testable import MeetingTranscriber
import XCTest

@MainActor
final class TerminalJobStoreTests: XCTestCase {
    private func record(
        id: UUID = UUID(),
        state: JobState = .done,
        title: String = "Meeting",
        transcript: String? = nil,
        proto: String? = nil,
    ) -> JobStatusDTO {
        JobStatusDTO(
            jobID: id.uuidString,
            state: state,
            meetingTitle: title,
            transcriptPath: transcript,
            protocolPath: proto,
            error: nil,
            warnings: [],
        )
    }

    // MARK: - Pure upsert/cap logic

    func testUpsertAppendsNewRecord() {
        let a = record(title: "A")
        let result = TerminalJobStore.upserting([], with: a, cap: 10)
        XCTAssertEqual(result, [a])
    }

    func testUpsertReplacesRecordWithSameJobID() {
        let id = UUID()
        let first = record(id: id, title: "Stale")
        let updated = record(id: id, title: "Fresh")
        let result = TerminalJobStore.upserting([first], with: updated, cap: 10)
        XCTAssertEqual(result, [updated], "Same jobID must replace, not duplicate")
    }

    func testUpsertCapsToMostRecent() {
        var records: [JobStatusDTO] = []
        let kept = (0 ..< 5).map { record(title: "job-\($0)") }
        for r in kept {
            records = TerminalJobStore.upserting(records, with: r, cap: 3)
        }
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.meetingTitle), ["job-2", "job-3", "job-4"])
    }

    // MARK: - File roundtrip + durability

    func testRecordThenLookupReturnsRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tjs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let store = TerminalJobStore(path: dir.appendingPathComponent("terminal_jobs.json"))
        store.record(record(id: id, transcript: "/out/t.txt", proto: "/out/p.md"))

        let found = store.lookup(jobID: id)
        XCTAssertEqual(found?.transcriptPath, "/out/t.txt")
        XCTAssertEqual(found?.protocolPath, "/out/p.md")
    }

    func testLookupUnknownReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tjs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TerminalJobStore(path: dir.appendingPathComponent("terminal_jobs.json"))
        XCTAssertNil(store.lookup(jobID: UUID()))
    }

    func testRecordSurvivesReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tjs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("terminal_jobs.json")
        let id = UUID()
        let writer = TerminalJobStore(path: path)
        writer.record(record(id: id, title: "Persisted"))

        // A fresh store reading the same path must see the persisted record,
        // proving readback survives the in-memory job reaping (the #431 bug).
        let reader = TerminalJobStore(path: path)
        XCTAssertEqual(reader.lookup(jobID: id)?.meetingTitle, "Persisted")
    }

    func testLoadFromCorruptFileReturnsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tjs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("terminal_jobs.json")
        try Data("not valid json {".utf8).write(to: path)

        // A corrupt store must never block startup or readback — it loads empty.
        let store = TerminalJobStore(path: path)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.lookup(jobID: UUID()))
    }

    func testRecordKeptInMemoryWhenPersistenceFails() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tjs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Parent path is a FILE, so createDirectory/write inside save() throws and
        // hits its best-effort catch — the just-finished job must still be held in
        // memory rather than lost to a persistence error.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let store = TerminalJobStore(path: blocker.appendingPathComponent("nested/terminal_jobs.json"))

        let id = UUID()
        store.record(record(id: id, title: "Unwritable"))

        XCTAssertEqual(
            store.lookup(jobID: id)?.meetingTitle, "Unwritable",
            "record is retained in memory even when persistence fails",
        )
    }
}
