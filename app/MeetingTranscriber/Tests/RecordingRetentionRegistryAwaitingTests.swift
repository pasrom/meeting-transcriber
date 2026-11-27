@testable import MeetingTranscriber
import XCTest

/// The compaction mark on a registry entry: its shape on disk and its
/// lifecycle per kind and root.
@MainActor
final class RecordingRetentionRegistryAwaitingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "retention_registry_awaiting")
    }

    override func tearDown() async throws {
        tmpDir = nil
        try await super.tearDown()
    }

    private var registryPath: URL {
        tmpDir.appendingPathComponent("retained_recordings.json")
    }

    private var root: URL {
        tmpDir.appendingPathComponent("Output", isDirectory: true)
    }

    private func entryJSON(awaiting: String? = nil) -> String {
        let extra = awaiting.map { #","awaiting":\#($0)"# } ?? ""
        return #"[{"jobID":"6F1C2A4E-0D3B-4C55-9A0E-1B2C3D4E5F60","paths":["file:///o/recordings/m_mix.wav"],"#
            + #""root":"file:///o/","recordedAt":0,"outputExported":false\#(extra)}]"#
    }

    func testAnEntryWithoutTheAwaitingKeyDecodes() throws {
        try Data(entryJSON().utf8).write(to: registryPath)

        let entries = RecordingRetentionRegistry(path: registryPath).entries

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.awaiting, [])
    }

    /// A kind a newer build added is dropped, not a reason to read the whole
    /// file as unreadable.
    func testAnUnknownKindIsDroppedAndTheEntryStays() throws {
        try Data(entryJSON(awaiting: #"["flac","somethingNew"]"#).utf8).write(to: registryPath)

        XCTAssertEqual(RecordingRetentionRegistry(path: registryPath).entries.first?.awaiting, [.flac])
    }

    func testTheAwaitingMarkSurvivesAReloadAndIsClearedPerKindAndRoot() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        let jobID = UUID()
        let other = tmpDir.appendingPathComponent("Other", isDirectory: true)
        registry.register(
            jobID: jobID, paths: [root.appendingPathComponent("recordings/m_mix.wav")], root: root, recordedAt: Date(),
        )
        registry.register(
            jobID: jobID, paths: [other.appendingPathComponent("recordings/m_app.wav")], root: other, recordedAt: Date(),
        )
        for entryRoot in [root, other] {
            registry.markAwaiting(.flac, jobID: jobID, root: entryRoot)
            registry.markAwaiting(.mixDrop, jobID: jobID, root: entryRoot)
        }
        XCTAssertFalse(registry.markAwaiting(.flac, jobID: UUID(), root: root), "a job with no entry there")

        XCTAssertTrue(registry.clearAwaiting(.flac, jobID: jobID, root: root))
        XCTAssertFalse(registry.clearAwaiting(.flac, jobID: jobID, root: root), "nothing left to clear")

        let reloaded = RecordingRetentionRegistry(path: registryPath).entries
        XCTAssertEqual(reloaded.first { $0.root == root }?.awaiting, [.mixDrop])
        XCTAssertEqual(reloaded.first { $0.root == other }?.awaiting, [.flac, .mixDrop])
    }

    /// A mark goes on the entry under the root asked for only: a run works
    /// under one output folder and could never clear one elsewhere.
    func testAMarkGoesOnTheEntryUnderItsRootOnly() {
        let registry = RecordingRetentionRegistry(path: registryPath)
        let jobID = UUID()
        let other = tmpDir.appendingPathComponent("Other", isDirectory: true)
        registry.register(
            jobID: jobID, paths: [root.appendingPathComponent("recordings/m_mix.wav")], root: root, recordedAt: Date(),
        )
        registry.register(
            jobID: jobID, paths: [other.appendingPathComponent("recordings/m_app.wav")], root: other, recordedAt: Date(),
        )

        registry.markAwaiting(.flac, jobID: jobID, root: other)

        XCTAssertEqual(registry.entry(of: jobID, under: root)?.awaiting, [])
        XCTAssertEqual(registry.entry(of: jobID, under: other)?.awaiting, [.flac])
    }

    /// Nothing pending writes no key, so the file reads to an older build
    /// exactly as before.
    func testAnEmptyMarkIsNotWritten() throws {
        let registry = RecordingRetentionRegistry(path: registryPath)
        registry.register(
            jobID: UUID(), paths: [root.appendingPathComponent("recordings/m_mix.wav")], root: root, recordedAt: Date(),
        )

        XCTAssertFalse(try String(contentsOf: registryPath, encoding: .utf8).contains("\"awaiting\""))
    }
}
