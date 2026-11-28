@testable import MeetingTranscriber
import os
import XCTest

/// What a kill at each step of the compactor leaves, taken from the real run:
/// the injected steps copy the recordings folder and the registry file at the
/// moment they are called, and each copy is then put back and checked as the
/// next launch would find it. Not seeded by hand, so a sequence that changed
/// order (the copy renamed before it is listed, the WAV removed before the
/// copy is in place) produces another state here and fails.
@MainActor
final class RecordingCompactionCrashTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var fixture: RetentionQueueFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try RetentionQueueFixture(tmpDir: makeTempDirectory(prefix: "compaction_crash"))
        fixture.enabled = false
    }

    override func tearDown() async throws {
        fixture = nil
        try await super.tearDown()
    }

    /// Run one finished recording through a compactor whose steps capture a
    /// snapshot at every crash point of every track, and return them.
    private func captureCrashStates() async throws -> [CrashSnapshot] {
        let snapshots = OSAllocatedUnfairLock<[CrashSnapshot]>(initialState: [])
        let recordings = fixture.recordingsDir
        let registryFile = fixture.registryFile
        let stash = fixture.tmpDir.appendingPathComponent("stash", isDirectory: true)
        @Sendable
        func capture(_ name: String) {
            guard let snapshot = try? CrashSnapshot.capture(
                name, recordings: recordings, registryFile: registryFile, stashRoot: stash,
            ) else { return }
            snapshots.withLock { $0.append(snapshot) }
        }
        let steps = RecordingCompactionWorker.Steps.live
            .with(\.prepare) { source, partial in
                try KeptRecordingCompressor().prepare(source: source, partial: partial)
                capture("after prepare \(source.lastPathComponent)")
            }
            .with(\.unlink) { url in
                capture("after rename \(url.lastPathComponent)")
                try RecordingFileDeleter.unlinkFile(url)
                capture("after unlink \(url.lastPathComponent)")
            }
        let renameAfterCapture: (URL, URL) throws -> Void = { from, to in
            capture("after register \(to.lastPathComponent)")
            try RecordingCompaction.renameExclusive(from, to)
        }
        let compaction = fixture.makeCompaction(steps: steps, rename: renameAfterCapture)
        let queue = fixture.makeQueue(compaction: compaction)
        let job = try fixture.makeRecordedJob(pcm16: true)
        try RecordingSidecar.writeTestRecordingSidecar(besideMix: XCTUnwrap(job.mixPath))
        queue.enqueue(job)
        await queue.processNext()
        await waitFor(!compaction.isRunning && compaction.awaitingCount == 0, timeout: .seconds(10))
        let taken = snapshots.withLock { $0 }
        XCTAssertEqual(taken.count, 12, "four crash points per track, three tracks")
        return taken
    }

    /// A fresh retention object and compactor on the restored registry file,
    /// as a relaunch builds them.
    private func relaunch() -> (retention: RecordingRetention, compaction: RecordingCompaction) {
        let registry = RecordingRetentionRegistry(path: fixture.registryFile)
        let retention = RecordingRetention(registry: registry) {
            RecordingRetentionSettings(enabled: true, days: 0)
        }
        let compaction = RecordingCompaction(
            registry: registry, isEnabled: { true },
            retentionSettings: { RecordingRetentionSettings(enabled: false, days: 0) },
        )
        compaction.codecStatus = .available
        return (retention, compaction)
    }

    private func visible(_ names: [String]) -> Set<String> {
        Set(names.filter { !$0.hasPrefix(".") })
    }

    /// At every crash point, every file under a track name is listed, and a
    /// due retention pass leaves nothing of the recording but, at most, the
    /// hidden partial the sweep removes once it is old.
    func testEveryCrashPointLeavesEveryFileListed() async throws {
        for snapshot in try await captureCrashStates() {
            try snapshot.restore()
            let names = CompactionDisk.recordingNames(in: fixture.recordingsDir)
            let listed = CompactionDisk.listedNames(at: fixture.registryFile)
            XCTAssertEqual(visible(names).subtracting(listed), [], "\(snapshot.name): unlisted files")

            let (retention, _) = relaunch()
            await retention.sweep(.init(excludedPaths: { [] }, scopeRoot: nil, securityScope: .live))

            let left = CompactionDisk.recordingNames(in: fixture.recordingsDir)
            XCTAssertEqual(visible(left), [], "\(snapshot.name): a due pass left part of the recording")
            XCTAssertTrue(left.allSatisfy(RecordingCompaction.isPartialCopy), "\(snapshot.name): left \(left)")
        }
    }

    private func size(of name: String) throws -> Int64 {
        let path = fixture.recordingsDir.appendingPathComponent(name).path
        return try Int64(XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int))
    }

    /// At every crash point the storage limit counts the recording as it is
    /// on disk: a listed name not created yet or already unlinked counts
    /// nothing, the hidden partial never counts, and, with the compactor
    /// active and the entry still marked, a track whose WAV and FLAC are both
    /// listed and on disk counts once, as the FLAC. Past the grace period it
    /// then deletes every visible file of the recording and, on the pass
    /// after, drops the entry.
    func testEveryCrashPointIsCountedAsItIsOnDiskAndFullyDeletedByTheSizeLimit() async throws {
        var checkedLastRename = false
        for snapshot in try await captureCrashStates() {
            try snapshot.restore()
            let names = visible(CompactionDisk.recordingNames(in: fixture.recordingsDir))
            let listed = CompactionDisk.listedNames(at: fixture.registryFile)
            XCTAssertEqual(
                CompactionDisk.entries(at: fixture.registryFile).first?.awaiting, [.flac], "\(snapshot.name): test premise",
            )
            let counted = names.filter { name in
                let flac = String(name.dropLast(3)) + "flac"
                return !(name.hasSuffix(".wav") && listed.contains(name) && listed.contains(flac) && names.contains(flac))
            }
            var expected = try counted.reduce(Int64(0)) { try $0 + size(of: $1) }
            if snapshot.name.hasPrefix("after rename"), snapshot.name.hasSuffix("_mic.wav") {
                // Every track has its FLAC now; only the mic's WAV is still
                // there, and it does not count: three FLACs and the sidecar.
                let explicit = try names.filter { $0.hasSuffix(".flac") || $0.hasSuffix(RecordingSidecar.recordingFilenameSuffix) }
                    .reduce(Int64(0)) { try $0 + size(of: $1) }
                XCTAssertEqual(names.count { $0.hasSuffix(".flac") }, 3, "test premise")
                XCTAssertEqual(names.count { $0.hasSuffix(".wav") }, 1, "test premise")
                XCTAssertEqual(expected, explicit, "the derived total disagrees with the explicit one")
                expected = explicit
                checkedLastRename = true
            }
            var clock = Date().addingTimeInterval(1)
            var reached: [Int64] = []
            let alarm = RecordingStorageAlarm.inMemory()
            let retention = RecordingRetention(
                registry: RecordingRetentionRegistry(path: fixture.registryFile),
                settings: { RecordingRetentionSettings(enabled: false, days: 0) },
                now: { clock },
                storageLimit: { RecordingStorageLimitSettings(enabled: true, limitBytes: 0) },
                alarm: alarm,
                onLimitReached: { total, _ in reached.append(total) },
                report: { _ in },
            )
            // The compactor a relaunch builds, with the setting on and FLAC
            // found, under this fixture's output folder.
            let compaction = RecordingCompaction(
                registry: retention.registry, isEnabled: { true },
                retentionSettings: { RecordingRetentionSettings(enabled: false, days: 0) },
            )
            compaction.codecStatus = .available
            let output = fixture.output
            retention.pairResolves = { { compaction.pairResolves($0, idleRoot: output) } }
            let context = RecordingRetention.SweepContext(excludedPaths: { [] }, scopeRoot: nil, securityScope: .live)

            await retention.sweep(context)
            XCTAssertEqual(reached, [expected], "\(snapshot.name): counted total")
            XCTAssertEqual(
                visible(CompactionDisk.recordingNames(in: fixture.recordingsDir)), names, "\(snapshot.name): the grace period",
            )

            clock = clock.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
            await retention.sweep(context)
            let left = CompactionDisk.recordingNames(in: fixture.recordingsDir)
            XCTAssertEqual(visible(left), [], "\(snapshot.name): the size limit left part of the recording")
            XCTAssertTrue(left.allSatisfy(RecordingCompaction.isPartialCopy), "\(snapshot.name): left \(left)")
            XCTAssertNil(alarm.load(), "\(snapshot.name): nothing counted is left")

            await retention.sweep(context)
            XCTAssertTrue(retention.registry.entries.isEmpty, "\(snapshot.name): the emptied entry stays listed")
        }
        XCTAssertTrue(checkedLastRename, "test premise: the snapshot after the last rename was taken")
    }

    /// From every crash point, the next run ends with exactly the FLAC tracks
    /// and the sidecar, all listed, no WAV, no partial, and the mark gone.
    func testASecondRunFinishesWhatACrashLeft() async throws {
        let states = try await captureCrashStates()
        let expected = Set(CompactionDisk.recordingNames(in: fixture.recordingsDir))
        XCTAssertEqual(expected.count { $0.hasSuffix(".flac") }, 3, "test premise: the full run converted all three")
        for snapshot in states {
            try snapshot.restore()
            let (_, compaction) = relaunch()

            await compaction.run(fixture.compactionContext())

            let names = CompactionDisk.recordingNames(in: fixture.recordingsDir)
            XCTAssertEqual(Set(names), expected, "\(snapshot.name)")
            XCTAssertEqual(CompactionDisk.listedNames(at: fixture.registryFile), expected, "\(snapshot.name): listing")
            XCTAssertEqual(CompactionDisk.entries(at: fixture.registryFile).first?.awaiting, [], "\(snapshot.name): mark")
            let mix = try XCTUnwrap(names.first { $0.hasSuffix("_mix.flac") })
            let sidecar = try XCTUnwrap(RecordingSidecar.read(from: XCTUnwrap(RecordingSidecar.recordingSidecarURL(
                besideMix: fixture.recordingsDir.appendingPathComponent(mix), extensions: RecordingFileSuffix.keptExtensions,
            ))))
            XCTAssertTrue(
                [sidecar.files.mix, sidecar.files.app, sidecar.files.mic].allSatisfy { $0?.hasSuffix(".flac") == true },
                "\(snapshot.name): the sidecar still names a WAV",
            )
        }
    }

    /// A run cut off on its second track has committed the first and left
    /// the second as a listed WAV with nothing but a hidden partial beside it.
    func testAnInterruptedRunLeavesTheSourceListedAndOnlyAHiddenPartial() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            if source.lastPathComponent.hasSuffix(RecordingFileSuffix.app) { await gate.pass() }
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let job = try fixture.makeRecordedJob(pcm16: true)
        queue.enqueue(job)
        await queue.processNext()
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        let names = CompactionDisk.recordingNames(in: fixture.recordingsDir)
        let listed = CompactionDisk.listedNames(at: fixture.registryFile)
        XCTAssertEqual(names.count { $0.hasSuffix("_mix.flac") }, 1, "the first track is committed")
        XCTAssertEqual(names.count { $0.hasSuffix("_mix.wav") }, 0)
        let app = try XCTUnwrap(names.first { $0.hasSuffix("_app.wav") }, "the second track's WAV is there")
        XCTAssertTrue(listed.contains(app))
        XCTAssertEqual(visible(names).subtracting(listed), [])
        XCTAssertEqual(names.filter { $0.hasPrefix(".") }.map(RecordingCompaction.isPartialCopy), [true])

        compaction.cancel()
        gate.open()
        await waitFor(!compaction.isRunning, timeout: .seconds(10))
    }
}
