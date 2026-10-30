@testable import MeetingTranscriber
import XCTest

/// The registry of relocated recordings on its own: what registering,
/// eligibility, renames and a damaged file do to its entries. Fresh temp
/// folders only.
@MainActor
final class RecordingRetentionRegistryTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var root: URL!
    private var recordingsDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "retention_registry")
        root = tmpDir.appendingPathComponent("Output", isDirectory: true)
        recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        tmpDir = nil
        root = nil
        recordingsDir = nil
        try await super.tearDown()
    }

    private var registryPath: URL {
        tmpDir.appendingPathComponent("logs/retained_recordings.json")
    }

    private var protocolFile: URL {
        root.appendingPathComponent("protocols/20270115_1200_sync.md")
    }

    /// A later relocation of the same job under a different output folder
    /// starts a second entry instead of widening the first, so each entry
    /// names one root.
    func testARelocationUnderAnotherRootStartsAnotherEntry() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        let jobID = UUID()
        let otherRoot = tmpDir.appendingPathComponent("Other", isDirectory: true)
        let first = recordingsDir.appendingPathComponent("a_mix.wav")
        let second = otherRoot.appendingPathComponent("recordings/a_app.wav")
        registry.register(jobID: jobID, paths: [first], root: root, recordedAt: now)
        registry.register(jobID: jobID, paths: [second], root: otherRoot, recordedAt: now)

        XCTAssertEqual(registry.entries.map(\.paths), [[first], [second]])
        registry.markEligible(jobID: jobID, output: protocolFile, at: now)
        XCTAssertTrue(registry.entries.allSatisfy { $0.eligibleAt != nil }, "both entries belong to the job")
    }

    func testRegistryPersistsAcrossInstancesOwnerOnly() throws {
        let first = RecordingRetentionRegistry(path: registryPath)
        let mix = recordingsDir.appendingPathComponent("a_mix.wav")
        let jobID = UUID()
        first.register(jobID: jobID, paths: [mix], root: root, recordedAt: now)
        first.markEligible(jobID: jobID, output: protocolFile, at: now)

        let second = RecordingRetentionRegistry(path: registryPath)
        XCTAssertEqual(second.entries, first.entries)
        XCTAssertEqual(second.entries.first?.eligibleAt, now)

        let attributes = try FileManager.default.attributesOfItem(atPath: registryPath.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    /// A second relocation of the same job adds to its entry instead of
    /// replacing it, and keeps the first recording date.
    func testRegisteringAJobAgainMergesItsPaths() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        let jobID = UUID()
        let mix = recordingsDir.appendingPathComponent("a_mix.wav")
        let app = recordingsDir.appendingPathComponent("a_app.wav")
        registry.register(jobID: jobID, paths: [mix], root: root, recordedAt: now)
        registry.register(
            jobID: jobID, paths: [mix, app], root: root,
            recordedAt: now.addingTimeInterval(60),
        )

        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertEqual(registry.entries.first?.paths, [mix, app])
        XCTAssertEqual(registry.entries.first?.recordedAt, now)
    }

    /// A file name can come free and be taken again: a user deletes an older
    /// meeting's audio and protocol by hand, and the next meeting with the same
    /// AI title takes its stem. The newer registration owns the path, so the
    /// older entry cannot delete the newer meeting's audio on its own schedule.
    func testANewerRegistrationTakesOverAPathFromAnOlderEntry() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        let older = UUID()
        let newer = UUID()
        let mix = recordingsDir.appendingPathComponent("sprint_planning_mix.wav")
        let olderApp = recordingsDir.appendingPathComponent("20270101_sync_app.wav")
        registry.register(jobID: older, paths: [mix, olderApp], root: root, recordedAt: now)
        registry.register(jobID: newer, paths: [mix], root: root, recordedAt: now)

        XCTAssertEqual(registry.entries.first { $0.jobID == older }?.paths, [olderApp])
        XCTAssertEqual(registry.entries.first { $0.jobID == newer }?.paths, [mix])
    }

    /// The same through a rename: the renamed-to path leaves any older entry.
    func testARenameTakesOverAPathFromAnOlderEntry() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        let older = UUID()
        let newer = UUID()
        let taken = recordingsDir.appendingPathComponent("sprint_planning_mix.wav")
        let stamped = recordingsDir.appendingPathComponent("20270115_sync_mix.wav")
        registry.register(jobID: older, paths: [taken], root: root, recordedAt: now)
        registry.register(jobID: newer, paths: [stamped], root: root, recordedAt: now)

        registry.repoint(jobID: newer, moves: [(from: stamped, to: taken)])

        XCTAssertNil(registry.entries.first { $0.jobID == older }, "an entry left with no paths is dropped")
        XCTAssertEqual(registry.entries.first { $0.jobID == newer }?.paths, [taken])
    }

    func testMarkingAnUnknownJobEligibleIsANoOp() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        registry.markEligible(jobID: UUID(), output: protocolFile, at: now)
        XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryPath.path))
    }

    /// A rename that moves the output after the job became eligible is
    /// followed too, or the cleaner would read the output as missing.
    func testRepointFollowsARenamedOutput() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        let jobID = UUID()
        let mix = recordingsDir.appendingPathComponent("a_mix.wav")
        let renamed = protocolFile.deletingLastPathComponent().appendingPathComponent("weekly_sync.md")
        registry.register(jobID: jobID, paths: [mix], root: root, recordedAt: now)
        registry.markEligible(jobID: jobID, output: protocolFile, at: now)

        registry.repoint(jobID: jobID, moves: [(from: protocolFile, to: renamed)])

        XCTAssertEqual(registry.entries.first?.outputPath, renamed)
    }

    func testRepointFollowsARenamedFile() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        let jobID = UUID()
        let old = recordingsDir.appendingPathComponent("20270115_1200_sync_mix.wav")
        let new = recordingsDir.appendingPathComponent("weekly_sync_mix.wav")
        registry.register(jobID: jobID, paths: [old], root: root, recordedAt: now)

        registry.repoint(jobID: jobID, moves: [(from: old, to: new)])

        XCTAssertEqual(registry.entries.first?.paths, [new])
    }

    /// An unreadable list is moved aside rather than overwritten by the next
    /// write, so the entries it held can still be recovered by hand.
    func testAnUnreadableRegistryFileIsKeptAside() throws {
        try FileManager.default.createDirectory(
            at: registryPath.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("not json".utf8).write(to: registryPath)
        let registry = RecordingRetentionRegistry(path: registryPath)
        registry.register(
            jobID: UUID(), paths: [recordingsDir.appendingPathComponent("b_mix.wav")], root: root, recordedAt: now,
        )

        let aside = registryPath.appendingPathExtension("unreadable")
        XCTAssertEqual(try Data(contentsOf: aside), Data("not json".utf8))
        XCTAssertEqual(RecordingRetentionRegistry(path: registryPath).entries.count, 1)
    }

    /// A list that is there but cannot be read (permissions, an I/O error) is
    /// not a missing one: it is moved aside too, never written over.
    func testARegistryFileThatCannotBeReadIsKeptAside() throws {
        try FileManager.default.createDirectory(
            at: registryPath.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let held = Data("[]".utf8)
        try held.write(to: registryPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: registryPath.path)
        let aside = registryPath.appendingPathExtension("unreadable")
        defer {
            for path in [registryPath, aside] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
        }

        let registry = RecordingRetentionRegistry(path: registryPath)
        registry.register(
            jobID: UUID(), paths: [recordingsDir.appendingPathComponent("b_mix.wav")], root: root, recordedAt: now,
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path)
        XCTAssertEqual(try Data(contentsOf: aside), held, "the unreadable list must survive the next write")
    }

    func testACorruptRegistryFileLoadsEmpty() throws {
        try FileManager.default.createDirectory(
            at: registryPath.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("not json".utf8).write(to: registryPath)
        XCTAssertTrue(RecordingRetentionRegistry(path: registryPath).entries.isEmpty)
    }
}
