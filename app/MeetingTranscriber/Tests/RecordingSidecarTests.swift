@testable import MeetingTranscriber
import XCTest

final class RecordingSidecarTests: XCTestCase {
    private func makeFullSidecar() -> RecordingSidecar {
        RecordingSidecar(
            title: "Standup",
            appName: "Microsoft Teams",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_777_001_800),
            participants: ["Alice", "Bob"],
            micDelaySeconds: 0.12,
            trigger: .manual,
            mixFilename: "20260503_083000_mix.wav",
            appFilename: "20260503_083000_app.wav",
            micFilename: "20260503_083000_mic.wav",
        )
    }

    /// Writes `json` under the sidecar's own naming convention and reads it
    /// back through the real `read()` path, which swallows decode errors —
    /// a bespoke decoder here would not show what production actually gets.
    private func readRawSidecar(_ json: String) throws -> RecordingSidecar? {
        let dir = try makeTempDirectory(prefix: "rs-raw")
        let basename = "raw"
        let url = dir.appendingPathComponent("\(basename)\(RecordingSidecar.filenameSuffix)")
        try Data(json.utf8).write(to: url)
        return RecordingSidecar.read(fromDirectory: dir, basename: basename)
    }

    private func encodeAsDict(_ sidecar: RecordingSidecar) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    func test_encode_includesAllFields() throws {
        let sidecar = makeFullSidecar()
        let dict = try encodeAsDict(sidecar)

        XCTAssertEqual(dict["version"] as? Int, 2)
        XCTAssertEqual(dict["title"] as? String, "Standup")
        XCTAssertEqual(dict["appName"] as? String, "Microsoft Teams")
        XCTAssertEqual(dict["participants"] as? [String], ["Alice", "Bob"])
        XCTAssertEqual(dict["micDelaySeconds"] as? Double, 0.12)
        XCTAssertEqual(dict["trigger"] as? String, "manual")
        XCTAssertNotNil(dict["startedAt"] as? String)
        XCTAssertNotNil(dict["stoppedAt"] as? String)

        let files = dict["files"] as? [String: Any]
        XCTAssertEqual(files?["mix"] as? String, "20260503_083000_mix.wav")
        XCTAssertEqual(files?["app"] as? String, "20260503_083000_app.wav")
        XCTAssertEqual(files?["mic"] as? String, "20260503_083000_mic.wav")
    }

    func test_encode_omitsMicAndAppWhenNil() throws {
        let sidecar = RecordingSidecar(
            title: "Solo",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_777_000_600),
            participants: [],
            micDelaySeconds: 0,
            trigger: .auto,
            mixFilename: "mix.wav",
            appFilename: nil,
            micFilename: nil,
        )
        let dict = try encodeAsDict(sidecar)
        let files = dict["files"] as? [String: Any]
        XCTAssertNotNil(files)
        XCTAssertEqual(files?["mix"] as? String, "mix.wav")
        XCTAssertNil(files?["app"], "app filename should be omitted when nil")
        XCTAssertNil(files?["mic"], "mic filename should be omitted when nil")
    }

    func test_write_createsFileNextToBasename() throws {
        let dir = try makeTempDirectory(prefix: "rs")

        let basename = "20260503_083000"
        let sidecar = makeFullSidecar()
        let url = try sidecar.write(toDirectory: dir, basename: basename)

        XCTAssertEqual(url.lastPathComponent, "\(basename)_meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_read_roundTripsTitleAndParticipants() throws {
        let dir = try makeTempDirectory(prefix: "rs")
        let basename = "20260503_083000"
        try makeFullSidecar().write(toDirectory: dir, basename: basename)

        let decoded = try XCTUnwrap(
            RecordingSidecar.read(fromDirectory: dir, basename: basename),
        )

        XCTAssertEqual(decoded.title, "Standup")
        XCTAssertEqual(decoded.appName, "Microsoft Teams")
        XCTAssertEqual(decoded.participants, ["Alice", "Bob"])
        XCTAssertEqual(decoded.micDelaySeconds, 0.12, accuracy: 0.0001)
        XCTAssertEqual(decoded.files.mix, "20260503_083000_mix.wav")
        XCTAssertEqual(decoded.trigger, .manual)
    }

    func test_read_returnsNilWhenMissing() throws {
        let dir = try makeTempDirectory(prefix: "rs")
        XCTAssertNil(RecordingSidecar.read(fromDirectory: dir, basename: "absent"))
    }

    /// Sidecars written before the trigger field existed must keep decoding.
    /// `read()` swallows decode errors, so a non-optional field here would
    /// silently degrade every reimport of an older recording to stem-derived
    /// defaults (title, participants and meeting-start all lost).
    func test_read_v1SidecarWithoutTrigger_decodesWithNilTrigger() throws {
        let decoded = try XCTUnwrap(readRawSidecar(
            """
            {
              "version": 1,
              "title": "Legacy Standup",
              "appName": "Zoom",
              "startedAt": "2026-05-03T08:30:00Z",
              "stoppedAt": "2026-05-03T09:00:00Z",
              "participants": ["Speaker A"],
              "micDelaySeconds": 0.5,
              "files": { "mix": "legacy_mix.wav" }
            }
            """,
        ))

        XCTAssertNil(decoded.trigger)
        XCTAssertEqual(decoded.title, "Legacy Standup")
        XCTAssertEqual(decoded.participants, ["Speaker A"])
    }

    /// A trigger value from a future schema version must map to nil rather than
    /// throw. A throw would poison the whole read, so an old build would lose
    /// every other field too instead of just the one it cannot interpret.
    func test_read_unknownTriggerValue_keepsRemainingFields() throws {
        let decoded = try XCTUnwrap(readRawSidecar(
            """
            {
              "version": 3,
              "title": "Future Standup",
              "appName": "Zoom",
              "startedAt": "2026-05-03T08:30:00Z",
              "stoppedAt": "2026-05-03T09:00:00Z",
              "participants": ["Speaker A"],
              "micDelaySeconds": 0.5,
              "trigger": "scheduled",
              "files": { "mix": "future_mix.wav" }
            }
            """,
        ))

        XCTAssertNil(decoded.trigger, "an unknown trigger value must decode as nil, not throw")
        XCTAssertEqual(decoded.title, "Future Standup")
        XCTAssertEqual(decoded.files.mix, "future_mix.wav")
    }

    /// The sidecar records meeting title + participants; it must be owner-only
    /// (0600), not world-readable, matching the audio it sits next to.
    func test_write_setsOwnerOnlyPermissions() throws {
        let dir = try makeTempDirectory(prefix: "rs")
        let url = try makeFullSidecar().write(toDirectory: dir, basename: "20260503_083000")

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int,
        )
        XCTAssertEqual(mode & 0o777, 0o600)
    }
}
