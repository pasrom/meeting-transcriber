@testable import MeetingTranscriber
import XCTest

/// The storage limit's pure parts: step, selection, Settings lines and the
/// stored warning. The size pass itself is in `RecordingStorageLimitTests`.
final class RecordingStorageLimitPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 250)

    func testStepFollowsTheGracePeriod() {
        let warning = RecordingStorageWarning(since: start, limitBytes: 250, root: nil)
        let step = { (total: Int64, warning: RecordingStorageWarning?, now: Date) in
            RecordingStorageLimitPolicy.step(
                totalBytes: total, settings: self.limit, warning: warning, root: nil, now: now,
            )
        }
        XCTAssertEqual(step(250, nil, start), .clear, "at the limit is not over it")
        XCTAssertEqual(step(251, nil, start), .warn)
        XCTAssertEqual(step(251, warning, start.addingTimeInterval(86399)), .wait)
        XCTAssertEqual(step(251, warning, start.addingTimeInterval(86400)), .delete)
        XCTAssertEqual(
            RecordingStorageLimitPolicy.step(totalBytes: 999, settings: .off, warning: warning, root: nil, now: start),
            .clear,
        )
    }

    /// A warning covers its own limit or a higher one, and its own folder.
    func testAWarningForAHigherLimitOrAnotherFolderWarnsAgain() {
        let warning = RecordingStorageWarning(since: start, limitBytes: 250, root: "/a")
        let later = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        let step = { (limit: Int64, root: String?) in
            RecordingStorageLimitPolicy.step(
                totalBytes: 1000, settings: .init(enabled: true, limitBytes: limit), warning: warning,
                root: root, now: later,
            )
        }
        XCTAssertEqual(step(250, "/a"), .delete)
        XCTAssertEqual(step(500, "/a"), .delete, "raising the limit keeps the warning")
        XCTAssertEqual(step(100, "/a"), .warn, "a lower limit than the one warned about")
        XCTAssertEqual(step(250, "/b"), .warn, "another output folder")
        XCTAssertEqual(step(250, nil), .warn)
    }

    func testStatusLinesShowUsageAndThePendingDeletion() {
        let calm = RecordingStorageLimitRows.statusLines(
            .init(totalBytes: 2_000_000_000, keptBytes: 0, warning: nil), now: start,
        )
        XCTAssertEqual(calm, ["Recordings use 2 GB."])

        let warning = RecordingStorageWarning(since: start, limitBytes: 1, root: nil)
        let status = RecordingStorageStatus(totalBytes: 2_000_000_000, keptBytes: 500_000_000, warning: warning)
        let over = RecordingStorageLimitRows.statusLines(status, now: start)
        XCTAssertEqual(over.count, 2)
        XCTAssertEqual(over[0], "Recordings use 2 GB, 500 MB of it cannot be deleted yet.")
        XCTAssertTrue(over[1].contains(start.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertTrue(over[1].contains(warning.deletesFrom.formatted(date: .abbreviated, time: .shortened)))
    }

    /// Once the delete time has passed, the line no longer names it.
    func testStatusLinesSayDeletingOnceTheGracePeriodIsOver() {
        let warning = RecordingStorageWarning(since: start, limitBytes: 1, root: nil)
        let status = RecordingStorageStatus(totalBytes: 2_000_000_000, keptBytes: 0, warning: warning)
        let lines = RecordingStorageLimitRows.statusLines(status, now: warning.deletesFrom.addingTimeInterval(7 * 86400))
        XCTAssertFalse(lines[1].contains(warning.deletesFrom.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertTrue(lines[1].contains("are being deleted"))
    }

    /// Stored data that does not decode reads as no warning.
    func testAnUndecodableStoredWarningLoadsAsNone() throws {
        let suite = "RecordingStorageLimitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        defer { DefaultsSuite.remove(suite) }
        defaults.set(Data("not json".utf8), forKey: RecordingStorageAlarm.key)
        XCTAssertNil(RecordingStorageAlarm.defaults(defaults).load())
    }

    func testSelectsOldestFirstUntilUnderTheLimit() {
        let make = { (age: Double, bytes: Int64) in
            RecordingStorageLimitPolicy.Candidate(
                jobID: UUID(), recordedAt: self.start.addingTimeInterval(-age * 86400), eligibleAt: self.start,
                urls: [], bytes: bytes,
            )
        }
        let newest = make(1, 100), middle = make(2, 100), oldest = make(3, 100)
        let picked = RecordingStorageLimitPolicy.selectForDeletion(
            [newest, oldest, middle], totalBytes: 350, limitBytes: 200,
        )
        XCTAssertEqual(picked, [oldest, middle])
    }
}
