@testable import MeetingTranscriber
import os
import XCTest

/// The storage limit's size pass over a recording whose track is listed and
/// on disk both as WAV and as its FLAC copy: what the compactor leaves
/// between naming the copy and unlinking the WAV, and until the next run
/// when that unlink fails or the app quits in between. Whether the pair
/// counts once is the compactor's answer (`RecordingCompaction.pairResolves`),
/// asked of a real compactor on the same registry; a seeded registry stands
/// for the states it leaves. Real files in a temp folder.
@MainActor
final class RecordingStorageLimitBothContainersTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var root: URL!
    private var recordingsDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 150)
    private var reached: [(Int64, Int64)] = []
    private var statuses: [RecordingStorageStatus?] = []
    private var alarm = RecordingStorageAlarm.inMemory()
    /// The FLAC setting the compactor reads.
    private var compressionOn = true
    /// What the compactor's launch probe found.
    private var codec = KeptRecordingCodecStatus.available
    /// The folder the next compaction run would work under; the output root
    /// unless a test moves it.
    private var idleRoot: URL?
    /// Paths an unfinished job holds, for retention's held paths.
    private var held: Set<String> = []

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "recording_storage_limit_both")
        root = tmpDir.appendingPathComponent("Output", isDirectory: true)
        recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)
        idleRoot = root
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: protocolFile.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("# Protocol".utf8).write(to: protocolFile)
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

    /// The compactor the last `makeRetention` built.
    private var compaction: RecordingCompaction?

    /// A retention object and, on its registry, the compactor whose answer
    /// it asks, wired as the controller wires them.
    private func makeRetention(
        deleter: RecordingFileDeleter = RecordingFileDeleter(), steps: RecordingCompactionWorker.Steps = .live,
    ) -> RecordingRetention {
        let retention = RecordingRetention(
            registry: RecordingRetentionRegistry(path: tmpDir.appendingPathComponent("logs/retained.json")),
            settings: { RecordingRetentionSettings(enabled: false, days: 30) },
            now: { [weak self] in self?.now ?? Date() },
            deleter: deleter,
            storageLimit: { [weak self] in self?.limit ?? .off },
            alarm: alarm,
            onLimitReached: { [weak self] in self?.reached.append(($0, $1)) },
            onStatus: { [weak self] in self?.statuses.append($0) },
            report: { _ in },
        )
        let compaction = RecordingCompaction(
            registry: retention.registry, isEnabled: { [weak self] in self?.compressionOn ?? false },
            retentionSettings: { RecordingRetentionSettings(enabled: false, days: 30) },
            worker: RecordingCompactionWorker(steps: steps),
        )
        compaction.codecStatus = codec
        self.compaction = compaction
        retention.pairResolves = { [weak self] in
            let idleRoot = self?.idleRoot
            return { compaction.pairResolves($0, idleRoot: idleRoot) }
        }
        retention.heldPaths = { [weak self] in self?.held ?? [] }
        return retention
    }

    /// A deleter whose unlink fails for every WAV and every file `failing`
    /// says so for.
    private func failingDeleter(_ failing: @escaping @Sendable (URL) -> Bool = { $0.pathExtension == "wav" }) -> RecordingFileDeleter {
        RecordingFileDeleter { url in
            guard !failing(url) else { throw POSIXError(.EACCES) }
            try RecordingFileDeleter.unlinkFile(url)
        }
    }

    /// Holds the first delete until the test signals `release`, after
    /// setting `reached`, so the test can act on the main actor mid-pass.
    private final class FirstDeleteGate: Sendable {
        let reached = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)

        var deleter: RecordingFileDeleter {
            RecordingFileDeleter { [self] url in
                let first = reached.withLock { state -> Bool in
                    defer { state = true }
                    return !state
                }
                if first { release.wait() }
                try RecordingFileDeleter.unlinkFile(url)
            }
        }
    }

    private let context = RecordingRetention.SweepContext(excludedPaths: { [] }, scopeRoot: nil, securityScope: .live)

    /// A recording recorded `ageDays` before `start` whose mix is `sizes`
    /// bytes per container, listed in that order, under `under` (the output
    /// root by default), notes saved `now` when `eligible`, marked as owed
    /// FLAC when `marked`. Returns its files.
    @discardableResult
    private func register(
        in retention: RecordingRetention, ageDays: Double, eligible: Bool = true, marked: Bool = false,
        sizes: [(fileExtension: String, bytes: Int)] = [("wav", 100)], jobID: UUID = UUID(), under: URL? = nil,
    ) throws -> [URL] {
        let base: URL = under ?? root
        let folder = base.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = folder.appendingPathComponent("rec_\(ageDays)_mix").path
        let files = sizes.map { URL(fileURLWithPath: "\(stem).\($0.fileExtension)") }
        for (url, size) in zip(files, sizes) {
            try Data(repeating: 1, count: size.bytes).write(to: url)
        }
        retention.registry.register(
            jobID: jobID, paths: files, root: base, recordedAt: start.addingTimeInterval(-ageDays * 86400),
        )
        if eligible { retention.registry.markEligible(jobID: jobID, output: protocolFile, at: now) }
        if marked { retention.registry.markAwaiting(.flac, jobID: jobID, root: base) }
        return files
    }

    /// The mix as a 100-byte WAV and its 40-byte FLAC, listed in `order`,
    /// marked as owed FLAC unless `marked` is false: a run would finish it.
    @discardableResult
    private func registerInBothContainers(
        in retention: RecordingRetention, ageDays: Double, eligible: Bool = true, marked: Bool = true,
        order: [String] = ["wav", "flac"], jobID: UUID = UUID(), under: URL? = nil,
    ) throws -> [URL] {
        let bytes = ["wav": 100, "flac": 40]
        return try register(
            in: retention, ageDays: ageDays, eligible: eligible, marked: marked,
            sizes: order.map { ($0, bytes[$0] ?? 0) }, jobID: jobID, under: under,
        )
    }

    /// A warning stored at `now`, then the clock moved past its grace period.
    private func storeWarningPastItsGracePeriod() {
        alarm.save(RecordingStorageWarning(since: now, limitBytes: limit.limitBytes, root: nil))
        now = now.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
    }

    private func exists(_ urls: [URL]) -> Bool {
        urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func gone(_ urls: [URL]) -> Bool {
        !urls.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The track counts once, as its FLAC: 100 + 40 bytes fit 150.
    func testATrackInBothContainersCountsOnceAsItsFLAC() async throws {
        let retention = makeRetention()
        try register(in: retention, ageDays: 2)
        try registerInBothContainers(in: retention, ageDays: 1, eligible: false)

        await retention.sweep(context)

        XCTAssertTrue(reached.isEmpty, "warned about a WAV that only waits for its unlink")
        XCTAssertEqual(statuses.last??.totalBytes, 140)
    }

    /// A FLAC listed but not on disk yet (named before the rename creates
    /// it) leaves the WAV counted.
    func testAWAVWhoseFLACIsNotOnDiskStillCounts() async throws {
        let retention = makeRetention()
        let files = try registerInBothContainers(in: retention, ageDays: 1, eligible: false)
        try FileManager.default.removeItem(at: files[1])

        await retention.sweep(context)

        XCTAssertEqual(statuses.last??.totalBytes, 100)
    }

    /// Over the limit, the pass deletes only what the counted total needs:
    /// one old recording, not a second one for the WAV the FLAC replaces.
    func testATrackInBothContainersDoesNotCostASecondRecording() async throws {
        let retention = makeRetention()
        let oldest = try register(in: retention, ageDays: 3)
        let older = try register(in: retention, ageDays: 2)
        let both = try registerInBothContainers(in: retention, ageDays: 1, eligible: false)
        storeWarningPastItsGracePeriod()

        await retention.sweep(context)

        XCTAssertTrue(gone(oldest), "control: the pass reached its delete step")
        XCTAssertTrue(exists(older), "a second recording went for a WAV its FLAC replaces")
        XCTAssertTrue(exists(both))
        XCTAssertNil(alarm.load(), "140 bytes left fit the limit")
    }

    /// Deleting a recording in both containers removes both files but frees
    /// only what was counted, the FLAC, so the pass goes on until the total
    /// really fits and does not clear the warning early.
    func testDeletingATrackInBothContainersFreesWhatWasCounted() async throws {
        let retention = makeRetention()
        let both = try registerInBothContainers(in: retention, ageDays: 3)
        let older = try register(in: retention, ageDays: 2)
        let newest = try register(in: retention, ageDays: 1)
        storeWarningPastItsGracePeriod()

        await retention.sweep(context)

        XCTAssertTrue(gone(both), "a deleted recording kept a listed file")
        XCTAssertTrue(gone(older), "240 counted bytes less the FLAC's 40 is still over")
        XCTAssertTrue(exists(newest))
        XCTAssertNil(alarm.load())
        XCTAssertEqual(statuses.last??.totalBytes, 100)
    }

    /// After the deletes, what is left is measured as counted: a recording
    /// in both containers that became deletable after the warning does not
    /// make an inflated remainder look over the limit and warn again.
    func testATrackInBothContainersDoesNotWarnAgainAfterTheDeletes() async throws {
        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 100)
        let retention = makeRetention()
        let covered = try register(in: retention, ageDays: 2)
        storeWarningPastItsGracePeriod()
        let both = try registerInBothContainers(in: retention, ageDays: 1)

        await retention.sweep(context)

        XCTAssertTrue(gone(covered), "control: the pass reached its delete step")
        XCTAssertTrue(exists(both), "not covered by the warning")
        XCTAssertTrue(reached.isEmpty, "warned again on a remainder that counted the WAV")
        XCTAssertNil(alarm.load(), "the FLAC's 40 bytes fit the limit")
    }

    // MARK: - Only while a run will resolve the pair

    /// With the setting off no run removes the WAV, so both files count: the
    /// limit stays a cap on what is really on disk.
    func testWithTheSettingOffATrackInBothContainersCountsBoth() async throws {
        compressionOn = false
        let retention = makeRetention()
        try registerInBothContainers(in: retention, ageDays: 1, eligible: false)

        await retention.sweep(context)

        XCTAssertEqual(statuses.last??.totalBytes, 140, "a WAV no run will remove went uncounted")
    }

    /// The probe found no FLAC: no run converts anything, both files count.
    func testWithNoFLACATrackInBothContainersCountsBoth() async throws {
        codec = .unavailable(reason: "notNativeFLAC")
        let retention = makeRetention()
        try registerInBothContainers(in: retention, ageDays: 1, eligible: false)

        await retention.sweep(context)

        XCTAssertEqual(statuses.last??.totalBytes, 140, "a WAV no run will remove went uncounted")
    }

    /// Before the launch probe answers, a run is still expected (the same
    /// rule that marks finished jobs), so the pair counts once: the first
    /// pass after a launch is the one that meets a pair a quit left.
    func testBeforeTheProbeAnswersATrackInBothContainersCountsOnce() async throws {
        codec = .unknown
        let retention = makeRetention()
        try registerInBothContainers(in: retention, ageDays: 1, eligible: false)

        await retention.sweep(context)

        XCTAssertEqual(statuses.last??.totalBytes, 40, "the launch pass counted a WAV the launch run removes")
    }

    /// An entry no run will take (not marked) counts both files too.
    func testAnUnmarkedTrackInBothContainersCountsBoth() async throws {
        let retention = makeRetention()
        try registerInBothContainers(in: retention, ageDays: 1, eligible: false, marked: false)

        await retention.sweep(context)

        XCTAssertEqual(statuses.last??.totalBytes, 140, "a WAV no run will remove went uncounted")
    }

    /// A run works only under the folder it is given, so a pair marked under
    /// another output folder counts both files, and one under the folder the
    /// next run uses counts once.
    func testAPairUnderAnotherOutputFolderCountsBoth() async throws {
        let retention = makeRetention()
        let earlier = tmpDir.appendingPathComponent("Earlier", isDirectory: true)
        try registerInBothContainers(in: retention, ageDays: 2, eligible: false, under: earlier)
        try registerInBothContainers(in: retention, ageDays: 1, eligible: false)

        await retention.sweep(context)

        XCTAssertEqual(statuses.last??.totalBytes, 140 + 40, "the earlier folder's WAV went uncounted, or this one's counted")
    }

    /// A run keeps the folder it started with when the next run would get
    /// another one: a pair it will still reach under its folder counts once.
    func testAPairUnderTheFolderOfARunGoingOnCountsOnce() async throws {
        let gate = StepGate()
        defer { gate.open() }
        let retention = makeRetention(steps: RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        })
        // A real recording first, which the run converts and holds there.
        let wav = recordingsDir.appendingPathComponent("rec_9_mix.wav")
        let samples = (0 ..< AudioConstants.targetSampleRate).map { Float(Int16(clamping: $0 % 4000)) / 32768 }
        try AudioMixer.saveWAV(samples: samples, sampleRate: AudioConstants.targetSampleRate, url: wav)
        let jobID = UUID()
        retention.registry.register(jobID: jobID, paths: [wav], root: root, recordedAt: start)
        retention.registry.markAwaiting(.flac, jobID: jobID, root: root)
        let pair = try registerInBothContainers(in: retention, ageDays: 1, eligible: false)
        let compaction = try XCTUnwrap(self.compaction)
        // Held by a job, so this run passes the pair over and its mark stays.
        let pairKeys = Set(pair.map(RecordingRetentionPolicy.pathKey))
        compaction.heldPaths = { pairKeys }
        let root: URL = root
        let run = Task {
            await compaction.run(.init(
                excludedPaths: { [] }, repointJobAudio: { _, _, _ in }, outputRoot: root, scopeRoot: nil, securityScope: .live,
            ))
        }
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        idleRoot = tmpDir.appendingPathComponent("Elsewhere", isDirectory: true)

        await retention.sweep(context)

        let wavSize = try Int64(XCTUnwrap(FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int))
        XCTAssertEqual(statuses.last??.totalBytes, wavSize + 40, "the run's own folder was taken for one no run reaches")
        gate.open()
        await run.value

        // The run is over and the next would go elsewhere: no run reaches
        // the pair now, so both files count.
        await retention.sweep(context)

        let flac = try XCTUnwrap(KeptRecordingCompressor.compressedURL(for: wav))
        let flacSize = try Int64(XCTUnwrap(FileManager.default.attributesOfItem(atPath: flac.path)[.size] as? Int))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "test premise: the run converted the recording")
        XCTAssertEqual(statuses.last??.totalBytes, flacSize + 140, "a finished run's folder still counted as reached")
    }

    // MARK: - What a delete frees

    /// A WAV whose unlink fails while its FLAC goes is counted in full again
    /// afterwards, so the pass does not clear the warning on a total it did
    /// not reach, and the next pass retries under the same warning instead of
    /// warning again and restarting the grace period.
    func testAFailedWAVDeleteKeepsTheWarning() async throws {
        let retention = makeRetention(deleter: failingDeleter())
        let both = try registerInBothContainers(in: retention, ageDays: 3)
        try register(in: retention, ageDays: 1, eligible: false, sizes: [("wav", 150)])
        storeWarningPastItsGracePeriod()
        let warning = alarm.load()

        await retention.sweep(context)

        XCTAssertTrue(exists([both[0]]) && gone([both[1]]), "test premise: the WAV stayed, the FLAC went")
        XCTAssertEqual(alarm.load(), warning, "cleared on a total the failed delete did not reach")
        XCTAssertEqual(statuses.last??.totalBytes, 250)

        await retention.sweep(context)

        XCTAssertTrue(reached.isEmpty, "warned again instead of retrying under the stored warning")
        XCTAssertEqual(alarm.load(), warning)
        XCTAssertEqual(statuses.last??.totalBytes, 250)
    }

    /// Listed FLAC first, and the recording taken into use while its FLAC is
    /// being deleted: the per-file check stops the pass before the WAV, and
    /// what is left counts as it now stands, the WAV in full.
    func testAnEntryCutOffAfterItsFLACKeepsTheWarning() async throws {
        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 130)
        let gate = FirstDeleteGate()
        defer { gate.release.signal() }
        let retention = makeRetention(deleter: gate.deleter)
        let both = try registerInBothContainers(in: retention, ageDays: 3, order: ["flac", "wav"])
        let newer = try register(in: retention, ageDays: 1)
        storeWarningPastItsGracePeriod()
        let warning = alarm.load()

        let pass = Task { await retention.sweep(context) }
        await waitFor(gate.reached.withLock { $0 }, timeout: .seconds(5))
        held = Set(both.map(RecordingRetentionPolicy.pathKey))
        gate.release.signal()
        await pass.value

        XCTAssertTrue(gone([both[0]]) && exists([both[1]]), "test premise: the FLAC went, the WAV was kept")
        XCTAssertTrue(exists(newer), "140 counted bytes less the FLAC's 40 fit, so only the oldest was picked")
        XCTAssertEqual(alarm.load(), warning, "cleared on a total the cut-off delete did not reach")
        XCTAssertEqual(statuses.last??.totalBytes, 200)
    }

    /// One job with an entry under each of two output folders: the pair
    /// under the current folder counts once, the other's both. A failed
    /// delete of the other entry frees nothing, whatever its sibling counts.
    func testAFailedDeleteOfOneOfAJobsTwoEntriesFreesNothing() async throws {
        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 100)
        let earlier = tmpDir.appendingPathComponent("Earlier", isDirectory: true)
        let retention = makeRetention(deleter: failingDeleter { $0.path.hasPrefix(earlier.path) })
        let jobID = UUID()
        // The current folder's entry first, and held by a job so it is no
        // candidate: a lookup by job alone finds it, not the one deleted.
        let current = try registerInBothContainers(in: retention, ageDays: 3, jobID: jobID)
        held = Set(current.map(RecordingRetentionPolicy.pathKey))
        let other = try registerInBothContainers(in: retention, ageDays: 3, marked: false, jobID: jobID, under: earlier)
        XCTAssertEqual(retention.registry.entries.count, 2, "test premise: two entries of one job")
        storeWarningPastItsGracePeriod()
        let warning = alarm.load()

        await retention.sweep(context)

        XCTAssertTrue(exists(other), "test premise: the delete under the earlier folder failed")
        XCTAssertEqual(alarm.load(), warning, "cleared on bytes the failed delete did not free")
        XCTAssertEqual(statuses.last??.totalBytes, 140 + 40)
    }

    /// The compactor converts a later picked recording while the pass is
    /// deleting an earlier one: the WAV it removed is not freed by the pass,
    /// and the FLAC it wrote still counts.
    func testARecordingConvertedMidPassIsNotCreditedAsFreed() async throws {
        limit = RecordingStorageLimitSettings(enabled: true, limitBytes: 120)
        let gate = FirstDeleteGate()
        defer { gate.release.signal() }
        let retention = makeRetention(deleter: gate.deleter)
        let oldest = try register(in: retention, ageDays: 3)
        let converted = try register(in: retention, ageDays: 2, marked: true)
        try register(in: retention, ageDays: 1, eligible: false)
        storeWarningPastItsGracePeriod()
        let warning = alarm.load()

        let pass = Task { await retention.sweep(context) }
        await waitFor(gate.reached.withLock { $0 }, timeout: .seconds(5))
        // What the compactor does: takes the entry in work, lists and writes
        // the FLAC, unlinks the WAV and forgets it.
        let entry = try XCTUnwrap(retention.registry.entries.first { $0.paths.contains(converted[0]) })
        let flac = try XCTUnwrap(KeptRecordingCompressor.compressedURL(for: converted[0]))
        held = Set((entry.paths + [flac]).map(RecordingRetentionPolicy.pathKey))
        retention.registry.register(jobID: entry.jobID, paths: [flac], root: entry.root, recordedAt: entry.recordedAt)
        try Data(repeating: 2, count: 40).write(to: flac)
        try FileManager.default.removeItem(at: converted[0])
        retention.registry.forget([converted[0]], of: entry.jobID)
        gate.release.signal()
        await pass.value

        XCTAssertTrue(gone(oldest), "control: the pass reached its delete step")
        XCTAssertEqual(alarm.load(), warning, "cleared on a WAV the compactor removed and a FLAC still there")
        XCTAssertEqual(statuses.last??.totalBytes, 100 + 40)
    }
}
