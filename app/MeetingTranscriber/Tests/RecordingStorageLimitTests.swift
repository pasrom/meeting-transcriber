@testable import MeetingTranscriber
import XCTest

/// The storage limit: the pure step and selection, then the cleaner's size
/// pass against real files in a temp folder.
@MainActor
final class RecordingStorageLimitTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var root: URL!
    private var recordingsDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 250)
    private var reached: [(Int64, Int64)] = []

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "recording_storage_limit")
        root = tmpDir.appendingPathComponent("Output", isDirectory: true)
        recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: protocolFile.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("# Protocol".utf8).write(to: protocolFile)
        now = start
        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 250)
        reached = []
    }

    override func tearDown() async throws {
        tmpDir = nil
        root = nil
        recordingsDir = nil
        try await super.tearDown()
    }

    private var protocolFile: URL {
        root.appendingPathComponent("protocols/notes.md")
    }

    private func makeRetention() -> RecordingRetention {
        RecordingRetention(
            registry: RecordingRetentionRegistry(path: tmpDir.appendingPathComponent("logs/retained.json")),
            settings: { RecordingRetentionSettings(enabled: false, days: 30) },
            now: { [weak self] in self?.now ?? Date() },
            storageLimit: { [weak self] in self?.limit ?? .off },
            onLimitReached: { [weak self] in self?.reached.append(($0, $1)) },
            report: { _ in },
        )
    }

    private var context: RecordingRetention.SweepContext {
        .init(excludedPaths: { [] }, scopeRoot: nil, securityScope: .live)
    }

    /// One 100-byte track recorded `ageDays` before `start`.
    @discardableResult
    private func register(
        in retention: RecordingRetention, ageDays: Double, eligible: Bool = true,
    ) throws -> URL {
        let url = recordingsDir.appendingPathComponent("rec_\(ageDays)_mix.wav")
        try Data(repeating: 1, count: 100).write(to: url)
        let jobID = UUID()
        retention.registry.register(
            jobID: jobID, paths: [url], root: root, recordedAt: start.addingTimeInterval(-ageDays * 86400),
        )
        if eligible { retention.registry.markEligible(jobID: jobID, output: protocolFile, at: start) }
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Policy

    func testStepFollowsTheGracePeriod() {
        let since = start
        let step = { (total: Int64, since: Date?, now: Date) in
            RecordingStorageLimitPolicy.step(totalBytes: total, settings: self.limit, exceededSince: since, now: now)
        }
        XCTAssertEqual(step(250, nil, start), .clear, "at the limit is not over it")
        XCTAssertEqual(step(251, nil, start), .warn)
        XCTAssertEqual(step(251, since, start.addingTimeInterval(86399)), .wait)
        XCTAssertEqual(step(251, since, start.addingTimeInterval(86400)), .delete)
        XCTAssertEqual(
            RecordingStorageLimitPolicy.step(totalBytes: 999, settings: .off, exceededSince: since, now: start),
            .clear,
        )
    }

    func testSelectsOldestFirstUntilUnderTheLimit() {
        let make = { (age: Double, bytes: Int64) in
            RecordingStorageLimitPolicy.Candidate(
                jobID: UUID(), recordedAt: self.start.addingTimeInterval(-age * 86400), urls: [], bytes: bytes,
            )
        }
        let newest = make(1, 100), middle = make(2, 100), oldest = make(3, 100)
        let picked = RecordingStorageLimitPolicy.selectForDeletion(
            [newest, oldest, middle], totalBytes: 350, limitBytes: 200,
        )
        XCTAssertEqual(picked, [oldest, middle])
    }

    // MARK: - Size pass

    func testOverTheLimitNotifiesOnceAndDeletesNothingYet() async throws {
        let retention = makeRetention()
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }

        await retention.sweep(context)
        now = start.addingTimeInterval(3600)
        await retention.sweep(context)

        XCTAssertEqual(reached.count, 1, "one notification per time over the limit")
        XCTAssertEqual(reached.first?.0, 300)
        XCTAssertEqual(reached.first?.1, 250)
        XCTAssertTrue(files.allSatisfy(exists), "nothing is deleted within the grace period")
    }

    func testAfterTheGracePeriodDeletesTheOldestUntilUnderTheLimit() async throws {
        let retention = makeRetention()
        let newest = try register(in: retention, ageDays: 1)
        let middle = try register(in: retention, ageDays: 2)
        let oldest = try register(in: retention, ageDays: 3)

        await retention.sweep(context)
        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)

        XCTAssertFalse(exists(oldest))
        XCTAssertTrue(exists(middle), "200 bytes fit the 250-byte limit")
        XCTAssertTrue(exists(newest))
        XCTAssertEqual(retention.registry.entries.count, 2)

        try register(in: retention, ageDays: 0.5)
        await retention.sweep(context)
        XCTAssertEqual(reached.count, 2, "fitting again clears the warning, so the next time over warns again")
    }

    /// Lowering the limit acts only once the setting has settled, so a value
    /// the stepper passes through never warns.
    func testALowerLimitWaitsForTheSettingToSettle() async throws {
        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 1000)
        let retention = makeRetention()
        try [1.0, 2, 3].forEach { try register(in: retention, ageDays: $0) }

        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 250)
        await retention.sweep(context)
        XCTAssertTrue(reached.isEmpty, "the unsettled lower limit must not act")

        retention.settle()
        await retention.sweep(context)
        XCTAssertEqual(reached.count, 1)
    }

    /// A recording whose outputs are not written yet counts but is kept.
    func testARecordingWithoutOutputsIsNeverDeleted() async throws {
        let retention = makeRetention()
        let pending = try register(in: retention, ageDays: 3, eligible: false)
        let done = try register(in: retention, ageDays: 1)
        let deletable = try register(in: retention, ageDays: 2)

        await retention.sweep(context)
        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)

        XCTAssertTrue(exists(pending), "the oldest is passed over: its outputs are not written")
        XCTAssertFalse(exists(deletable), "the oldest deletable one goes instead")
        XCTAssertTrue(exists(done))
    }

    /// With the age rule off, the size pass forgets recordings deleted by hand.
    func testForgetsARecordingDeletedByHand() async throws {
        let retention = makeRetention()
        let url = try register(in: retention, ageDays: 1)
        try FileManager.default.removeItem(at: url)

        await retention.sweep(context)

        XCTAssertTrue(retention.registry.entries.isEmpty)
    }

    func testFallingUnderTheLimitResetsTheGracePeriod() async throws {
        let retention = makeRetention()
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }

        await retention.sweep(context)
        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 1000)
        retention.settle()
        await retention.sweep(context)
        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 250)
        retention.settle()
        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)

        XCTAssertEqual(reached.count, 2, "going over again warns again")
        XCTAssertTrue(files.allSatisfy(exists), "the new grace period starts at the second warning")
    }

    func testOffDeletesNothing() async throws {
        limit = .off
        let retention = makeRetention()
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }

        await retention.sweep(context)
        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod * 2)
        await retention.sweep(context)

        XCTAssertTrue(reached.isEmpty)
        XCTAssertTrue(files.allSatisfy(exists))
    }

    // MARK: - Wiring

    /// The controller's cleaner reads both settings and notifies the user.
    func testControllerCleanerNotifiesFromTheSettings() async throws {
        let suite = "RecordingStorageLimitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        defer { DefaultsSuite.remove(suite) }
        let settings = AppSettings(defaults: defaults, apiKeyAccount: "\(suite)-openAI")
        defer { KeychainHelper.delete(key: "\(suite)-openAI") }
        settings.recordingStorageLimitEnabled = true
        settings.recordingStorageLimitGB = 1
        let notifier = RecordingNotifier()
        let retention = PipelineController.makeRecordingRetention(
            logDir: tmpDir.appendingPathComponent("logs"), settings: settings, notifier: notifier,
        )
        let url = recordingsDir.appendingPathComponent("big_mix.wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1_000_000_001)
        try handle.close()
        retention.registry.register(jobID: UUID(), paths: [url], root: root, recordedAt: start)

        await retention.sweep(context)

        XCTAssertEqual(notifier.calls.map(\.title), ["Recording storage limit reached"])
        XCTAssertNotNil(settings.recordingStorageAlarm.load(), "the warning time is kept across launches")
    }
}
