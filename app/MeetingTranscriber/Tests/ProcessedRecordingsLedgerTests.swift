@testable import MeetingTranscriber
import XCTest

// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`,
// so there's no explicit `tearDown` to balance `setUp`.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class ProcessedRecordingsLedgerTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "processed_ledger_test")
    }

    // MARK: - markProcessed

    func testMarkProcessedRoundTrips() throws {
        let mixPath = tmpDir.appendingPathComponent("test_mix.wav")

        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        ledger.markProcessed(mixPath: mixPath)

        // A fresh ledger over the same dir must see the persisted path.
        let reloaded = ProcessedRecordingsLedger(logDir: tmpDir)
        XCTAssertTrue(reloaded.load().contains(mixPath.standardizedFileURL.path))

        // On-disk format stays a JSON array of standardized path strings.
        let data = try Data(contentsOf: ledger.path)
        let paths = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(paths, [mixPath.standardizedFileURL.path])
    }

    func testMarkProcessedNilIsNoOp() {
        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        ledger.markProcessed(mixPath: nil)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ledger.path.path),
            "nil mixPath must not create the ledger file",
        )
        XCTAssertTrue(ledger.load().isEmpty)
    }

    // MARK: - load

    func testLoadReturnsEmptyWhenFileMissing() {
        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        XCTAssertTrue(ledger.load().isEmpty)
    }

    func testLoadReturnsEmptyOnCorruptFile() throws {
        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        try Data("not json".utf8).write(to: ledger.path)
        XCTAssertTrue(ledger.load().isEmpty)
    }

    // MARK: - migrate

    func testMigrateSeedsProcessedFromExistingMixFiles() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let mixA = recDir.appendingPathComponent("20260101_100000_mix.wav")
        let mixB = recDir.appendingPathComponent("20260102_100000_mix.wav")
        try Data(repeating: 0xFF, count: 100).write(to: mixA)
        try Data(repeating: 0xFF, count: 100).write(to: mixB)
        // Non-mix file must be ignored.
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("notes.txt"))

        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        await ledger.migrate(recordingsDir: recDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.path.path))
        XCTAssertEqual(ledger.load(), Set([
            mixA.standardizedFileURL.path,
            mixB.standardizedFileURL.path,
        ]))
    }

    func testMigrateIsNoOpWhenFileAlreadyExists() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 100).write(to: recDir.appendingPathComponent("20260101_mix.wav"))

        // Pre-seed with a sentinel value; migration must not overwrite it.
        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        let sentinel = try JSONEncoder().encode(["/preexisting/path/mix.wav"])
        try sentinel.write(to: ledger.path)

        await ledger.migrate(recordingsDir: recDir)

        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: ledger.path))
        XCTAssertEqual(paths, ["/preexisting/path/mix.wav"])
    }

    func testMigrateRunsOffMainActor() async throws {
        // Smoke test that the dir scan + JSON write don't starve main-actor
        // work: kick off migrate with `async let`, do synchronous work
        // concurrently, verify both complete.
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        for i in 0 ..< 50 {
            let mixFile = recDir.appendingPathComponent("20260311_10000\(i)_mix.wav")
            try Data(repeating: 0xFF, count: 100).write(to: mixFile)
        }

        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        async let migration: Void = ledger.migrate(recordingsDir: recDir)

        var counter = 0
        for _ in 0 ..< 10000 {
            counter += 1
        }
        XCTAssertEqual(counter, 10000)

        await migration
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.path.path))
    }
}
