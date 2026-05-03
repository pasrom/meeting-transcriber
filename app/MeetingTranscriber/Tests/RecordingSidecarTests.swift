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
            mixFilename: "20260503_083000_mix.wav",
            appFilename: "20260503_083000_app.wav",
            micFilename: "20260503_083000_mic.wav",
        )
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

        XCTAssertEqual(dict["version"] as? Int, 1)
        XCTAssertEqual(dict["title"] as? String, "Standup")
        XCTAssertEqual(dict["appName"] as? String, "Microsoft Teams")
        XCTAssertEqual(dict["participants"] as? [String], ["Alice", "Bob"])
        XCTAssertEqual(dict["micDelaySeconds"] as? Double, 0.12)
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
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let basename = "20260503_083000"
        let sidecar = makeFullSidecar()
        let url = try sidecar.write(toDirectory: dir, basename: basename)

        XCTAssertEqual(url.lastPathComponent, "\(basename)_meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
