// swiftlint:disable file_length
@testable import MeetingTranscriber
import XCTest

/// The registry and the cleaner that acts on it, against real files in a
/// fresh temp folder. The queue's side (who writes entries and when) is in
/// `PipelineQueueRetentionTests`.
@MainActor
final class RecordingRetentionTests: XCTestCase { // swiftlint:disable:this type_body_length
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var root: URL!
    private var recordingsDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional
    private var enabled = true
    private var days = 0
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "recording_retention")
        root = tmpDir.appendingPathComponent("Output", isDirectory: true)
        recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: protocolFile.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("# Protocol".utf8).write(to: protocolFile)
        enabled = true
        days = 0
    }

    override func tearDown() async throws {
        tmpDir = nil
        root = nil
        recordingsDir = nil
        try await super.tearDown()
    }

    /// The saved output every finished test recording points at.
    private var protocolFile: URL {
        root.appendingPathComponent("protocols/20270115_1200_sync.md")
    }

    private var registryPath: URL {
        tmpDir.appendingPathComponent("logs/retained_recordings.json")
    }

    private func makeRetention(
        registry: RecordingRetentionRegistry? = nil,
        deleter: RecordingFileDeleter = RecordingFileDeleter(),
        report: @escaping (RecordingRetentionPassSummary) -> Void = { _ in },
    ) -> RecordingRetention {
        RecordingRetention(
            registry: registry ?? RecordingRetentionRegistry(path: registryPath),
            settings: { [weak self] in
                RecordingRetentionSettings(enabled: self?.enabled ?? false, days: self?.days ?? 0)
            },
            now: { [now] in now },
            deleter: deleter,
            report: report,
        )
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = recordingsDir.appendingPathComponent(name)
        try Data("RIFF".utf8).write(to: url)
        return url
    }

    /// No scope held unless a test hands one over, as for an output folder
    /// that did not come from a bookmark.
    private func context(
        excluded: Set<String> = [], scope: SecurityScopeAccess? = nil,
    ) -> RecordingRetention.SweepContext {
        .init(excludedPaths: { excluded }, scopeRoot: scope == nil ? nil : root, securityScope: scope ?? .live)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Registers a finished three-track recording made `ageDays` before `now`.
    private func registerFinished(in retention: RecordingRetention, ageDays: Double = 1) throws -> [URL] {
        let stem = "20270115_1200_sync_\(UUID().uuidString.prefix(8))"
        let paths = try [
            makeFile("\(stem)_mix.wav"), makeFile("\(stem)_app.wav"), makeFile("\(stem)_mic.wav"),
        ]
        let jobID = UUID()
        retention.registry.register(
            jobID: jobID, paths: paths, root: root,
            recordedAt: now.addingTimeInterval(-ageDays * 86400),
        )
        retention.registry.markEligible(jobID: jobID, output: protocolFile, at: now)
        return paths
    }

    // MARK: - Cleaner

    func testDeletesADueRecordingAndForgetsIt() async throws {
        let retention = makeRetention()
        let paths = try registerFinished(in: retention)

        await retention.sweep(context())

        XCTAssertFalse(paths.contains(where: exists), "every track of a due recording is deleted")
        XCTAssertTrue(retention.registry.entries.isEmpty, "a deleted recording leaves no entry behind")
    }

    /// The registry starts empty and the cleaner never lists the folder, so a
    /// file it was never told about survives any setting.
    func testAFileTheRegistryDoesNotNameIsNeverTouched() async throws {
        let retention = makeRetention()
        let preexisting = try makeFile("20250101_0900_old_meeting_mix.wav")

        await retention.sweep(context())

        XCTAssertTrue(exists(preexisting))
    }

    /// Switching off leaves files and entries alone; switching on later acts on
    /// them, because the switch is read on every pass, not captured.
    func testSwitchIsReadLiveAndOffLeavesEverythingInPlace() async throws {
        enabled = false
        let retention = makeRetention()
        let paths = try registerFinished(in: retention)

        await retention.sweep(context())
        XCTAssertTrue(paths.allSatisfy(exists), "switched off, nothing is deleted")
        XCTAssertEqual(retention.registry.entries.count, 1, "switched off, the entry is kept for later")

        enabled = true
        retention.settle()
        await retention.sweep(context())
        XCTAssertFalse(paths.contains(where: exists), "switched on, the backlog is cleared")
    }

    /// Lowering the threshold clears what is now past it, on the next pass.
    func testLoweringTheThresholdClearsTheBacklog() async throws {
        days = 30
        let retention = makeRetention()
        let paths = try registerFinished(in: retention, ageDays: 5)

        await retention.sweep(context())
        XCTAssertTrue(paths.allSatisfy(exists), "five days old is within thirty")

        days = 1
        retention.settle()
        await retention.sweep(context())
        XCTAssertFalse(paths.contains(where: exists), "five days old is past one")
    }

    func testAPathInUseKeepsTheWholeEntry() async throws {
        let retention = makeRetention()
        let paths = try registerFinished(in: retention)

        await retention.sweep(context(excluded: [RecordingRetentionPolicy.pathKey(paths[2])]))

        XCTAssertTrue(paths.allSatisfy(exists))
        XCTAssertEqual(retention.registry.entries.count, 1)
    }

    /// An unmounted output folder keeps the entry, so the files are deleted once
    /// the drive is back instead of being forgotten.
    func testAnUnreachableRootKeepsTheEntryForALaterPass() async throws {
        let retention = makeRetention()
        _ = try registerFinished(in: retention)
        let parked = tmpDir.appendingPathComponent("Unmounted")
        try FileManager.default.moveItem(at: root, to: parked)

        await retention.sweep(context())
        XCTAssertEqual(retention.registry.entries.count, 1, "an unreachable root must not drop the entry")

        try FileManager.default.moveItem(at: parked, to: root)
        await retention.sweep(context())
        XCTAssertTrue(retention.registry.entries.isEmpty, "back online, the recording is deleted")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)
        XCTAssertEqual(leftovers, [])
    }

    func testFilesTheUserAlreadyDeletedDropTheEntry() async throws {
        let retention = makeRetention()
        let paths = try registerFinished(in: retention)
        for path in paths {
            try FileManager.default.removeItem(at: path)
        }

        await retention.sweep(context())

        XCTAssertTrue(retention.registry.entries.isEmpty)
    }

    /// A file that could not be deleted stays listed, so the next pass retries
    /// it instead of leaving it behind for good.
    func testAFailedDeleteStaysListedForTheNextPass() async throws {
        let failing = RecordingFileDeleter { url in
            if url.lastPathComponent.hasSuffix(RecordingFileSuffix.mic) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        }
        let retention = makeRetention(deleter: failing)
        let paths = try registerFinished(in: retention)

        await retention.sweep(context())

        XCTAssertEqual(retention.registry.entries.map(\.paths), [[paths[2]]])
        XCTAssertFalse(exists(paths[0]))
        XCTAssertTrue(exists(paths[2]))
    }

    /// The deletes run off the main actor: a remove can stall for seconds on a
    /// folder Spotlight is indexing, and the main actor runs the UI.
    func testDeletesRunOffTheMainThread() async throws {
        let onMain = Locked<Bool>()
        let probing = RecordingFileDeleter { url in
            onMain.append(Thread.isMainThread)
            try FileManager.default.removeItem(at: url)
        }
        let retention = makeRetention(deleter: probing)
        _ = try registerFinished(in: retention)

        await retention.sweep(context())

        XCTAssertEqual(onMain.values.count, 3, "the probe must have seen every delete")
        XCTAssertEqual(onMain.values, [false, false, false])
    }

    /// The sandbox grants the output folder through the URL resolved from its
    /// bookmark, and only that object carries the grant. The cleaner therefore
    /// opens access on the root it is handed, around the deletes, and never on
    /// the `recordings` child.
    func testScopeIsOpenedOnTheRootAroundTheDeletes() async throws {
        let events = Locked<String>()
        let scope = SecurityScopeAccess(
            start: { events.append("start \($0.path)"); return true },
            stop: { events.append("stop \($0.path)") },
        )
        let probing = RecordingFileDeleter { url in
            events.append("delete")
            try FileManager.default.removeItem(at: url)
        }
        let retention = makeRetention(deleter: probing)
        _ = try registerFinished(in: retention)

        await retention.sweep(context(scope: scope))

        XCTAssertEqual(
            events.values,
            ["start \(root.path)", "delete", "delete", "delete", "stop \(root.path)"],
        )
    }

    /// Nothing due, no scope taken: a pass with nothing to delete touches no
    /// folder access at all.
    func testNoScopeIsOpenedWhenNothingIsDue() async throws {
        days = 30
        let events = Locked<String>()
        let scope = SecurityScopeAccess(
            start: { events.append("start \($0.path)"); return true },
            stop: { events.append("stop \($0.path)") },
        )
        let retention = makeRetention()
        _ = try registerFinished(in: retention)

        await retention.sweep(context(scope: scope))

        XCTAssertEqual(events.values, [])
    }

    // MARK: - Review findings

    /// A file taken into use between two deletes of a pass is not deleted:
    /// each delete is checked against the paths in use right before it runs.
    /// This revalidates between deletes; it does not make check and delete
    /// one step.
    func testAPathTakenIntoUseBetweenDeletesIsNotDeleted() async throws {
        let inUse = Locked<String>()
        let appTrack = Box<URL>()
        let probing = RecordingFileDeleter { url in
            if url.lastPathComponent.hasSuffix(RecordingFileSuffix.mix), let app = appTrack.value {
                inUse.append(RecordingRetentionPolicy.pathKey(app))
            }
            try FileManager.default.removeItem(at: url)
        }
        let retention = makeRetention(deleter: probing)
        let paths = try registerFinished(in: retention)
        appTrack.value = paths[1]

        await retention.sweep(.init(
            excludedPaths: { Set(inUse.values) }, scopeRoot: nil, securityScope: .live,
        ))

        XCTAssertFalse(exists(paths[0]), "deleted before anything held it")
        XCTAssertTrue(exists(paths[1]), "taken into use mid-pass, so kept")
        XCTAssertTrue(exists(paths[2]), "one track in use keeps the rest of the recording")
    }

    /// A newer recording that moves its file onto a path right after the old
    /// one was deleted keeps both its file and its listing: the pass forgets
    /// the path only for the entry it decided on.
    func testANewOwnerWhoTakesAPathDuringTheDeleteKeepsIt() async throws {
        let newer = UUID()
        let registryRef = Box<RecordingRetentionRegistry>()
        let root = try XCTUnwrap(self.root)
        let now = self.now
        let content = Data("newer meeting".utf8)
        let probing = RecordingFileDeleter { url in
            try FileManager.default.removeItem(at: url)
            guard url.lastPathComponent.hasSuffix(RecordingFileSuffix.mic) else { return }
            try content.write(to: url)
            // The main actor is suspended in the pass, awaiting this delete.
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    registryRef.value?.register(jobID: newer, paths: [url], root: root, recordedAt: now)
                }
            }
        }
        let retention = makeRetention(deleter: probing)
        registryRef.value = retention.registry
        let paths = try registerFinished(in: retention)

        await retention.sweep(context())

        XCTAssertEqual(try? Data(contentsOf: paths[2]), content, "the newer recording's file must survive the pass")
        let owner = retention.registry.entries.first { $0.jobID == newer }
        XCTAssertEqual(owner?.paths, [paths[2]], "the newer owner must still list the path")
    }

    /// A newer recording that takes a path over before the pass reaches it:
    /// its file is not deleted on the older entry's schedule.
    func testAPathTakenOverBeforeItsDeleteIsNotDeleted() async throws {
        let newer = UUID()
        let registryRef = Box<RecordingRetentionRegistry>()
        let micTrack = Box<URL>()
        let root = try XCTUnwrap(self.root)
        let now = self.now
        let content = Data("newer meeting".utf8)
        let probing = RecordingFileDeleter { url in
            try FileManager.default.removeItem(at: url)
            guard url.lastPathComponent.hasSuffix(RecordingFileSuffix.app), let mic = micTrack.value else { return }
            try content.write(to: mic)
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    registryRef.value?.register(jobID: newer, paths: [mic], root: root, recordedAt: now)
                }
            }
        }
        let retention = makeRetention(deleter: probing)
        registryRef.value = retention.registry
        let paths = try registerFinished(in: retention)
        micTrack.value = paths[2]

        await retention.sweep(context())

        XCTAssertEqual(try? Data(contentsOf: paths[2]), content, "the newer recording's file must survive the pass")
    }

    /// The unlink cannot remove a folder, so a folder that replaced a file
    /// after the last check survives the delete itself.
    func testTheUnlinkCannotRemoveAFolder() throws {
        let folder = recordingsDir.appendingPathComponent("raced_mix.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let inside = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: inside)

        XCTAssertThrowsError(try RecordingFileDeleter.unlinkFile(folder))
        XCTAssertTrue(exists(inside))
    }

    /// The deleter on its own refuses a folder and a link, whoever calls it.
    func testTheDeleterRemovesRegularFilesOnly() async throws {
        let folder = recordingsDir.appendingPathComponent("folder_mix.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let inside = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: inside)
        let link = recordingsDir.appendingPathComponent("link_mix.wav")
        let target = tmpDir.appendingPathComponent("elsewhere.wav")
        try Data("RIFF".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = try makeFile("plain_mix.wav")

        let gone = await RecordingFileDeleter().delete([folder, link, file])

        XCTAssertEqual(gone, [file])
        XCTAssertTrue(exists(inside))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    /// Only regular files are deleted. A listed path that is now a folder, or
    /// a symlink, is skipped and stays listed; a folder is never deleted with
    /// its contents.
    func testAFolderOrALinkAtAListedPathIsNotDeleted() async throws {
        let retention = makeRetention()
        let paths = try registerFinished(in: retention)
        try FileManager.default.removeItem(at: paths[0])
        try FileManager.default.createDirectory(at: paths[0], withIntermediateDirectories: false)
        let inside = paths[0].appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: inside)
        let target = tmpDir.appendingPathComponent("elsewhere.wav")
        try Data("RIFF".utf8).write(to: target)
        try FileManager.default.removeItem(at: paths[1])
        try FileManager.default.createSymbolicLink(at: paths[1], withDestinationURL: target)

        await retention.sweep(context())

        XCTAssertTrue(exists(inside), "a folder is never deleted")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: paths[1].path), "the link stays")
        XCTAssertFalse(exists(paths[2]), "the regular file is deleted")
        let listed = retention.registry.entries.flatMap(\.paths)
        XCTAssertEqual(Set(listed), Set([paths[0], paths[1]]), "skipped paths stay listed")
    }

    /// Nothing is deleted while the registry in memory is not on disk: after a
    /// crash, the older state on disk would name paths a newer recording owns.
    func testNothingIsDeletedWhileTheRegistryCannotBeSaved() async throws {
        let blocker = tmpDir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let unsaved = RecordingRetentionRegistry(path: blocker.appendingPathComponent("retained.json"))
        let retention = makeRetention(registry: unsaved)
        let paths = try registerFinished(in: retention)

        await retention.sweep(context())

        XCTAssertTrue(paths.allSatisfy(exists), "an unsaved registry must not delete")
    }

    /// A pass acts on settled settings. A value only passed through on the
    /// stepper (here 0 on the way from 36500) must not reach the hourly, the
    /// rebuild or the finished-job pass either.
    func testAPassActsOnTheSettledPeriodNotOnAPassingValue() async throws {
        days = 36500
        let retention = makeRetention()
        let paths = try registerFinished(in: retention)

        days = 0
        await retention.sweep(context())
        XCTAssertTrue(paths.allSatisfy(exists), "0 is not settled yet")

        retention.settle()
        await retention.sweep(context())
        XCTAssertFalse(paths.contains(where: exists), "settled, the shorter period applies")
    }

    /// Switching off, or lengthening the period, takes effect at once, before
    /// it settles: only the direction that deletes waits.
    func testSwitchingOffAppliesBeforeItSettles() async throws {
        let retention = makeRetention()
        let paths = try registerFinished(in: retention)

        enabled = false
        await retention.sweep(context())
        XCTAssertTrue(paths.allSatisfy(exists), "off applies at once")

        enabled = true
        days = 36500
        await retention.sweep(context())
        XCTAssertTrue(paths.allSatisfy(exists), "a longer period applies at once")
    }

    /// Switching off during a pass stops the deletes still to come; the
    /// switch is read again before each one.
    func testSwitchingOffDuringAPassStopsTheRemainingDeletes() async throws {
        let switchedOn = Box<Bool>()
        switchedOn.value = true
        let probing = RecordingFileDeleter { url in
            try FileManager.default.removeItem(at: url)
            if url.lastPathComponent.hasSuffix(RecordingFileSuffix.mix) { switchedOn.value = false }
        }
        let retention = RecordingRetention(
            registry: RecordingRetentionRegistry(path: registryPath),
            settings: { RecordingRetentionSettings(enabled: switchedOn.value ?? false, days: 0) },
            now: { [now] in now },
            deleter: probing,
        )
        let paths = try registerFinished(in: retention)

        await retention.sweep(context())

        XCTAssertFalse(exists(paths[0]))
        XCTAssertTrue(exists(paths[1]), "switched off mid-pass, the rest stays")
        XCTAssertTrue(exists(paths[2]))
    }

    /// Paths held by the current queue's jobs protect a file even when the
    /// pass started from an earlier queue, which no longer receives new jobs.
    func testThePathsOfTheCurrentQueueAreRespectedMidPass() async throws {
        let current = Locked<String>()
        let appTrack = Box<URL>()
        let probing = RecordingFileDeleter { url in
            if url.lastPathComponent.hasSuffix(RecordingFileSuffix.mix), let app = appTrack.value {
                current.append(RecordingRetentionPolicy.pathKey(app))
            }
            try FileManager.default.removeItem(at: url)
        }
        let retention = makeRetention(deleter: probing)
        retention.heldPaths = { Set(current.values) }
        let paths = try registerFinished(in: retention)
        appTrack.value = paths[1]

        await retention.sweep(context())

        XCTAssertTrue(exists(paths[1]), "held by the current queue")
        XCTAssertTrue(exists(paths[2]), "one track held keeps the rest")
    }

    /// When one of a job's entries is dropped, its entries under other roots
    /// stay: they name files that still exist.
    func testDroppingOneEntryKeepsTheJobsEntryUnderAnotherRoot() async {
        let retention = makeRetention()
        let jobID = UUID()
        let otherRoot = tmpDir.appendingPathComponent("Unmounted", isDirectory: true)
        let gone = recordingsDir.appendingPathComponent("a_mix.wav")
        let elsewhere = otherRoot.appendingPathComponent("recordings/a_app.wav")
        retention.registry.register(
            jobID: jobID, paths: [gone], root: root, recordedAt: now.addingTimeInterval(-86400),
        )
        retention.registry.register(
            jobID: jobID, paths: [elsewhere], root: otherRoot, recordedAt: now.addingTimeInterval(-86400),
        )
        retention.registry.markEligible(jobID: jobID, output: protocolFile, at: now)

        await retention.sweep(context())

        XCTAssertEqual(retention.registry.entries.map(\.paths), [[elsewhere]])
    }

    /// A scope that cannot be opened stops the pass: no delete is tried
    /// without it.
    func testAFailedScopeStopsThePass() async throws {
        let refusing = SecurityScopeAccess(start: { _ in false }, stop: { _ in })
        let retention = makeRetention()
        let paths = try registerFinished(in: retention)

        await retention.sweep(context(scope: refusing))

        XCTAssertTrue(paths.allSatisfy(exists))
    }

    // MARK: - Pass report

    /// Every pass that looks at entries reports what it found, including one
    /// that only keeps: a keep would otherwise leave no trace that the pass
    /// ran at all.
    func testAPassReportsWhatItDeletedAndWhyItKeptTheRest() async throws {
        var reports: [RecordingRetentionPassSummary] = []
        let retention = makeRetention { reports.append($0) }
        _ = try registerFinished(in: retention)
        let pending = try makeFile("20270115_1300_pending_mix.wav")
        retention.registry.register(jobID: UUID(), paths: [pending], root: root, recordedAt: now)

        await retention.sweep(context())

        XCTAssertEqual(
            reports.map(\.logLine),
            ["Retention pass: entries 2, due 1 (files 3), deleted files 3, dropped 0, kept 1 (awaitingOutputs 1)"],
        )
        XCTAssertFalse(
            reports.contains { $0.logLine.contains("sync") || $0.logLine.contains("pending") },
            "no file name, which carries the meeting title, reaches the line",
        )
    }

    /// Deletes that stop short show as fewer deleted than due files, which is
    /// what tells a cut-short pass from a complete one.
    func testAPassThatStopsShortReportsFewerDeletedThanDueFiles() async throws {
        let failing = RecordingFileDeleter { _ in throw POSIXError(.EACCES) }
        var reports: [RecordingRetentionPassSummary] = []
        let retention = makeRetention(deleter: failing) { reports.append($0) }
        _ = try registerFinished(in: retention)

        await retention.sweep(context())

        XCTAssertEqual(
            reports.map(\.logLine),
            ["Retention pass: entries 1, due 1 (files 3), deleted files 0, dropped 0, kept 0"],
        )
    }

    /// Off, or with nothing listed, a pass has nothing to say, so the hourly
    /// timer adds no line for everyone who never switches this on.
    func testAPassWithNothingToLookAtReportsNothing() async throws {
        var reports: [RecordingRetentionPassSummary] = []
        let retention = makeRetention { reports.append($0) }

        await retention.sweep(context())
        _ = try registerFinished(in: retention)
        enabled = false
        await retention.sweep(context())

        XCTAssertTrue(reports.isEmpty)
    }
}

/// One value handed between threads.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Collects values appended from any thread, in order.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }

    var values: [Value] {
        lock.withLock { stored }
    }
}
