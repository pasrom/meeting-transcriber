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
    private var statuses: [RecordingStorageStatus?] = []
    private var alarm = RecordingStorageAlarm.inMemory()

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
        statuses = []
        alarm = .inMemory()
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

    private func makeRetention(
        retentionDays: Int? = nil,
        registryPath: URL? = nil,
        deleter: RecordingFileDeleter = RecordingFileDeleter(),
        storageLimit: (() -> RecordingStorageLimitSettings)? = nil,
    ) -> RecordingRetention {
        RecordingRetention(
            registry: RecordingRetentionRegistry(
                path: registryPath ?? tmpDir.appendingPathComponent("logs/retained.json"),
            ),
            settings: { RecordingRetentionSettings(enabled: retentionDays != nil, days: retentionDays ?? 30) },
            now: { [weak self] in self?.now ?? Date() },
            deleter: deleter,
            storageLimit: storageLimit ?? { [weak self] in self?.limit ?? .off },
            alarm: alarm,
            onLimitReached: { [weak self] in self?.reached.append(($0, $1)) },
            onStatus: { [weak self] in self?.statuses.append($0) },
            report: { _ in },
        )
    }

    private var context: RecordingRetention.SweepContext {
        .init(excludedPaths: { [] }, scopeRoot: nil, securityScope: .live)
    }

    private func context(
        excluding excluded: @escaping () -> Set<String> = { [] }, scopeRoot: URL? = nil, scopeOpens: Bool = true,
    ) -> RecordingRetention.SweepContext {
        .init(
            excludedPaths: excluded, scopeRoot: scopeRoot,
            securityScope: SecurityScopeAccess(start: { _ in scopeOpens }, stop: { _ in }),
        )
    }

    /// One 100-byte track recorded `ageDays` before `start` (after it when
    /// negative), in `folder` of `under` (the output root by default), its
    /// notes saved `now` when `eligible`.
    @discardableResult
    private func register(
        in retention: RecordingRetention, ageDays: Double, eligible: Bool = true,
        under: URL? = nil, folder: String = "recordings",
    ) throws -> URL {
        let base: URL = under ?? root
        let dir = base.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rec_\(ageDays)_mix.wav")
        try Data(repeating: 1, count: 100).write(to: url)
        let jobID = UUID()
        retention.registry.register(
            jobID: jobID, paths: [url], root: base, recordedAt: start.addingTimeInterval(-ageDays * 86400),
        )
        if eligible { retention.registry.markEligible(jobID: jobID, output: protocolFile, at: now) }
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
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

    /// Stuck over the limit with nothing deletable, a recording made after the
    /// warning gets a warning of its own instead of going as soon as its
    /// notes are saved.
    func testARecordingMadeAfterTheWarningIsWarnedAboutBeforeItGoes() async throws {
        let retention = makeRetention()
        try [1.0, 2, 3].forEach { try register(in: retention, ageDays: $0, eligible: false) }
        await retention.sweep(context)
        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)
        XCTAssertEqual(reached.count, 1, "nothing deletable is no reason to warn again")

        let newest = try register(in: retention, ageDays: -0.5)
        await retention.sweep(context)
        XCTAssertTrue(exists(newest), "made after the warning, so not covered by it")
        XCTAssertEqual(reached.count, 2)
        XCTAssertEqual(alarm.load()?.since, now)

        now = now.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)
        XCTAssertFalse(exists(newest), "its own grace period is over")
    }

    /// Lowering the limit while a warning is stored warns again, even when
    /// the total was already over the old limit.
    func testLoweringTheLimitWhileWarnedWarnsAgain() async throws {
        let retention = makeRetention()
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }
        await retention.sweep(context)

        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 50)
        retention.settle()
        now = start.addingTimeInterval(3600)
        await retention.sweep(context)
        XCTAssertEqual(reached.count, 2)
        XCTAssertEqual(reached.last?.1, 50)

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)
        XCTAssertTrue(files.allSatisfy(exists), "the grace period runs from the second warning")
    }

    /// A warning given for one output folder does not count for another.
    func testAWarningForOneFolderDoesNotDeleteInAnother() async throws {
        let retention = makeRetention()
        try [1.0, 2, 3].forEach { try register(in: retention, ageDays: $0) }
        let other = tmpDir.appendingPathComponent("Other", isDirectory: true)
        let otherFiles = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0, under: other) }
        await retention.sweep(context(scopeRoot: root))
        XCTAssertEqual(reached.count, 1)

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context(scopeRoot: other))

        XCTAssertEqual(reached.count, 2)
        XCTAssertTrue(otherFiles.allSatisfy(exists))
    }

    /// Entries under another root than the scoped one neither count nor go.
    func testAScopedPassIgnoresEntriesUnderAnotherRoot() async throws {
        let retention = makeRetention()
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }

        await retention.sweep(context(scopeRoot: tmpDir.appendingPathComponent("Other")))

        XCTAssertTrue(reached.isEmpty)
        XCTAssertTrue(files.allSatisfy(exists))
    }

    func testAFolderWhoseAccessCannotBeOpenedDeletesNothing() async throws {
        let retention = makeRetention()
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }
        await retention.sweep(context(scopeRoot: root))

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context(scopeRoot: root, scopeOpens: false))

        XCTAssertTrue(files.allSatisfy(exists))
        XCTAssertNotNil(alarm.load(), "still over, so the warning stays")
    }

    /// A track an unfinished job holds is never picked, so the next oldest goes.
    func testATrackInUseIsNotPicked() async throws {
        let retention = makeRetention()
        let newest = try register(in: retention, ageDays: 1)
        let middle = try register(in: retention, ageDays: 2)
        let oldest = try register(in: retention, ageDays: 3)
        let held: () -> Set<String> = { [RecordingRetentionPolicy.pathKey(oldest)] }
        await retention.sweep(context(excluding: held))

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context(excluding: held))

        XCTAssertTrue(exists(oldest))
        XCTAssertFalse(exists(middle))
        XCTAssertTrue(exists(newest))
    }

    /// A track that comes into use after the pass measured is still kept by
    /// the check right before the delete.
    func testATrackThatComesIntoUseMidPassIsKept() async throws {
        let retention = makeRetention()
        try register(in: retention, ageDays: 1)
        try register(in: retention, ageDays: 2)
        let oldest = try register(in: retention, ageDays: 3)
        await retention.sweep(context)

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        var calls = 0
        await retention.sweep(context {
            calls += 1
            return calls > 1 ? [RecordingRetentionPolicy.pathKey(oldest)] : []
        })

        XCTAssertTrue(exists(oldest))
    }

    /// A recording whose notes file is gone keeps its audio.
    func testARecordingWhoseNotesAreGoneIsNeverDeleted() async throws {
        let retention = makeRetention()
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }
        try FileManager.default.removeItem(at: protocolFile)
        await retention.sweep(context)

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)

        XCTAssertTrue(files.allSatisfy(exists))
        XCTAssertEqual(statuses.last??.keptBytes, 300)
    }

    /// A listed file outside the recordings folder neither counts nor goes,
    /// even as the oldest recording once the grace period is over.
    func testAFileOutsideTheRecordingsFolderDoesNotCount() async throws {
        let retention = makeRetention()
        let newest = try register(in: retention, ageDays: 1)
        let middle = try register(in: retention, ageDays: 2)
        let oldest = try register(in: retention, ageDays: 3)
        let outside = try register(in: retention, ageDays: 4, folder: "elsewhere")

        await retention.sweep(context)
        XCTAssertEqual(statuses.last??.totalBytes, 300, "the outside file is not counted")

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)

        XCTAssertTrue(exists(outside))
        XCTAssertFalse(exists(oldest), "the oldest inside the folder goes instead")
        XCTAssertTrue(exists(middle))
        XCTAssertTrue(exists(newest))
    }

    /// An old recording whose notes only succeed after the warning, a retry
    /// say, is warned about again instead of going as soon as they are saved.
    func testARecordingWhoseNotesAreSavedAfterTheWarningIsWarnedAboutBeforeItGoes() async throws {
        let retention = makeRetention()
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0, eligible: false) }
        await retention.sweep(context)
        XCTAssertEqual(reached.count, 1)

        now = start.addingTimeInterval(7 * 86400)
        let oldest = try XCTUnwrap(retention.registry.entries.first { $0.paths == [files[2]] })
        retention.registry.markEligible(jobID: oldest.jobID, output: protocolFile, at: now)
        await retention.sweep(context)
        XCTAssertTrue(exists(files[2]), "made before the warning, but deletable only after it")
        XCTAssertEqual(reached.count, 2)

        now = now.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)
        XCTAssertFalse(exists(files[2]), "its own grace period is over")
    }

    /// A registry that cannot be saved stops the pass before it warns or deletes.
    func testARegistryThatCannotBeSavedSkipsThePass() async throws {
        let blocker = tmpDir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let retention = makeRetention(registryPath: blocker.appendingPathComponent("retained.json"))
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }

        await retention.sweep(context)

        XCTAssertTrue(reached.isEmpty)
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertTrue(files.allSatisfy(exists))
    }

    /// A delete that fails leaves the total over, so the warning stays and
    /// the next pass tries again without a new notification.
    func testAFailedDeleteKeepsTheWarning() async throws {
        let failing = RecordingFileDeleter { _ in throw POSIXError(.EACCES) }
        let retention = makeRetention(deleter: failing)
        let files = try [1.0, 2, 3].map { try register(in: retention, ageDays: $0) }
        await retention.sweep(context)

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)

        XCTAssertTrue(files.allSatisfy(exists))
        XCTAssertEqual(reached.count, 1)
        XCTAssertEqual(alarm.load()?.since, start)
    }

    /// Raising the limit while a pass deletes stops it once the new limit is met.
    func testRaisingTheLimitMidPassStopsTheDeletes() async throws {
        let live = LimitBox(.init(enabled: true, limitBytes: 50))
        let raising = RecordingFileDeleter { url in
            try RecordingFileDeleter.unlinkFile(url)
            live.value = .init(enabled: true, limitBytes: 1000)
        }
        let retention = makeRetention(deleter: raising) { live.value }
        let newest = try register(in: retention, ageDays: 1)
        let middle = try register(in: retention, ageDays: 2)
        let oldest = try register(in: retention, ageDays: 3)
        await retention.sweep(context)

        now = start.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
        await retention.sweep(context)

        XCTAssertFalse(exists(oldest))
        XCTAssertTrue(exists(middle), "the raised limit is met after the first delete")
        XCTAssertTrue(exists(newest))
        XCTAssertNil(alarm.load(), "under the raised limit")
    }

    /// With both rules on, the age pass runs first and the size pass measures
    /// what is left.
    func testBothRulesTogether() async throws {
        let retention = makeRetention(retentionDays: 30)
        let recent = try [1.0, 2].map { try register(in: retention, ageDays: $0) }
        let old = try register(in: retention, ageDays: 40)

        await retention.sweep(context)

        XCTAssertFalse(exists(old), "due by age")
        XCTAssertTrue(recent.allSatisfy(exists))
        XCTAssertTrue(reached.isEmpty, "200 bytes left fit the limit")
    }

    func testReportsTheStatusAfterEachPass() async throws {
        let retention = makeRetention()
        try register(in: retention, ageDays: 1, eligible: false)
        try [2.0, 3].forEach { try register(in: retention, ageDays: $0) }

        await retention.sweep(context)
        XCTAssertEqual(
            statuses.last, RecordingStorageStatus(totalBytes: 300, keptBytes: 100, warning: alarm.load()),
        )
        XCTAssertNotNil(alarm.load())

        limit = .off
        await retention.sweep(context)
        XCTAssertEqual(statuses.last, .some(nil), "off reports no status")
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
        XCTAssertNotNil(settings.recordingStorageAlarm.load(), "the warning is kept across launches")
        XCTAssertEqual(settings.recordingStorageStatus?.totalBytes, 1_000_000_001, "Settings sees the status")
    }
}

private final class LimitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RecordingStorageLimitSettings
    init(_ value: RecordingStorageLimitSettings) {
        stored = value
    }

    var value: RecordingStorageLimitSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
