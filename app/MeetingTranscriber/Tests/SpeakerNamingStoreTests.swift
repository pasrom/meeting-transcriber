@testable import MeetingTranscriber
import XCTest

/// Unit tests for `SpeakerNamingStore` — the naming-sidecar persistence layer
/// extracted from `PipelineQueue`. These exercise the disk I/O directly,
/// without constructing a whole `PipelineQueue`, which is the point of the
/// extraction.
final class SpeakerNamingStoreTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "speaker_naming_store_test")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    private func makeData(
        jobID: UUID = UUID(),
        title: String = "Standup",
        mapping: [String: String] = ["SPEAKER_0": "Alice"],
        embeddings: [String: [Float]] = ["SPEAKER_0": [0.1, 0.2]],
    ) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: jobID, meetingTitle: title,
            mapping: mapping, speakingTimes: ["SPEAKER_0": 60],
            embeddings: embeddings, audioPath: nil,
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            participants: [], isDualSource: false,
        )
    }

    // MARK: - slug

    func test_slug_differsForSameTitleDifferentJobs() {
        let slug1 = SpeakerNamingStore.slug(title: "Daily Standup", jobID: UUID())
        let slug2 = SpeakerNamingStore.slug(title: "Daily Standup", jobID: UUID())
        XCTAssertNotEqual(slug1, slug2)
    }

    func test_slug_isDeterministicForSameJob() {
        let id = UUID()
        XCTAssertEqual(
            SpeakerNamingStore.slug(title: "Daily Standup", jobID: id),
            SpeakerNamingStore.slug(title: "Daily Standup", jobID: id),
        )
    }

    func test_slug_embedsTitleAndShortID() {
        let id = UUID()
        let slug = SpeakerNamingStore.slug(title: "Daily Standup", jobID: id)
        XCTAssertTrue(slug.contains(PipelineJob.shortID(for: id)))
        XCTAssertTrue(slug.lowercased().contains("daily") && slug.lowercased().contains("standup"))
    }

    // MARK: - save / load round-trip

    func test_saveThenLoad_roundTripsMapping() throws {
        let store = SpeakerNamingStore(outputDir: tmpDir)
        let id = UUID()
        let slug = SpeakerNamingStore.slug(title: "Standup", jobID: id)
        try store.save(makeData(jobID: id, mapping: ["SPEAKER_0": "Alice"]), slug: slug)

        let loaded = try XCTUnwrap(store.load(slug: slug))
        XCTAssertEqual(loaded.mapping["SPEAKER_0"], "Alice")
        XCTAssertEqual(loaded.jobID, id)
    }

    /// FluidAudio embeddings can contain NaN/Inf for short/silent segments.
    /// The store must use the string round-trip float strategy so the sidecar
    /// still persists — a plain JSONEncoder rejects non-conforming floats.
    func test_saveThenLoad_survivesNonConformingFloats() throws {
        let store = SpeakerNamingStore(outputDir: tmpDir)
        let slug = "nan_test"
        try store.save(makeData(embeddings: ["SPEAKER_0": [.nan, .infinity, -.infinity, 0.5]]), slug: slug)

        let loaded = try XCTUnwrap(store.load(slug: slug))
        let emb = try XCTUnwrap(loaded.embeddings["SPEAKER_0"])
        XCTAssertEqual(emb.count, 4)
        XCTAssertTrue(emb[0].isNaN)
        XCTAssertEqual(emb[1], .infinity)
        XCTAssertEqual(emb[2], -.infinity)
        XCTAssertEqual(emb[3], 0.5)
    }

    func test_save_writesOwnerOnlyPermissions() throws {
        let store = SpeakerNamingStore(outputDir: tmpDir)
        let slug = "perm_test"
        try store.save(makeData(), slug: slug)

        let path = tmpDir.appendingPathComponent("recordings/\(slug)_naming.json")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int,
        )
        XCTAssertEqual(mode & 0o777, 0o600, "Naming sidecar carries voice embeddings — must be owner-only")
    }

    func test_load_missingFile_returnsNil() {
        let store = SpeakerNamingStore(outputDir: tmpDir)
        XCTAssertNil(store.load(slug: "does_not_exist"))
    }

    func test_save_nilOutputDir_isNoOp() throws {
        let store = SpeakerNamingStore(outputDir: nil)
        // Must neither throw nor crash; load is correspondingly nil.
        try store.save(makeData(), slug: "any")
        XCTAssertNil(store.load(slug: "any"))
    }

    // MARK: - delete / cleanup

    func test_deleteNamingJSON_removesOnlyTheNamingFile() throws {
        let store = SpeakerNamingStore(outputDir: tmpDir)
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let slug = "del_test"
        for suffix in ["_naming.json", "_16k.wav"] {
            try Data([0]).write(to: recordingsDir.appendingPathComponent("\(slug)\(suffix)"))
        }

        store.deleteNamingJSON(slug: slug)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recordingsDir.appendingPathComponent("\(slug)_naming.json").path,
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recordingsDir.appendingPathComponent("\(slug)_16k.wav").path,
        ), "deleteNamingJSON must not touch audio sidecars")
    }

    func test_cleanupSidecarFiles_removesAudioAndSegmentSidecars() throws {
        let store = SpeakerNamingStore(outputDir: tmpDir)
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let slug = "cleanup_test"
        let suffixes = ["_16k.wav", "_app_16k.wav", "_mic_16k.wav", "_segments.json"]
        for suffix in suffixes {
            try Data([0]).write(to: recordingsDir.appendingPathComponent("\(slug)\(suffix)"))
        }

        store.cleanupSidecarFiles(slug: slug)

        for suffix in suffixes {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: recordingsDir.appendingPathComponent("\(slug)\(suffix)").path,
                ),
                "\(suffix) should be deleted",
            )
        }
    }

    func test_cleanupSidecarFiles_nilSlug_isNoOp() {
        let store = SpeakerNamingStore(outputDir: tmpDir)
        // Must not throw or crash.
        store.cleanupSidecarFiles(slug: nil)
        store.deleteNamingJSON(slug: nil)
    }
}
