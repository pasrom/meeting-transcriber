import Foundation
import XCTest

@testable import MeetingTranscriber

final class IPCManagerTests: XCTestCase {

    private var tmpDir: URL!
    private var ipc: IPCManager!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipc-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        ipc = IPCManager(baseDir: tmpDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - loadSpeakerRequest

    func testLoadSpeakerRequestValid() {
        let json = """
        {
            "version": 1,
            "timestamp": "2026-03-03T10:00:00",
            "meeting_title": "Standup",
            "audio_samples_dir": "/tmp/samples",
            "speakers": [
                {
                    "label": "SPEAKER_00",
                    "auto_name": "Alice",
                    "confidence": 0.95,
                    "speaking_time_seconds": 60.0,
                    "sample_file": "SPEAKER_00.wav"
                }
            ]
        }
        """.data(using: .utf8)!
        try! json.write(to: tmpDir.appendingPathComponent("speaker_request.json"))

        let request = ipc.loadSpeakerRequest()

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.meetingTitle, "Standup")
        XCTAssertEqual(request?.speakers.count, 1)
        XCTAssertEqual(request?.speakers.first?.label, "SPEAKER_00")
    }

    func testLoadSpeakerRequestMissing() {
        // No file exists — should return nil
        XCTAssertNil(ipc.loadSpeakerRequest())
    }

    func testLoadSpeakerRequestInvalidJSON() {
        let garbage = "not json at all {{{".data(using: .utf8)!
        try! garbage.write(to: tmpDir.appendingPathComponent("speaker_request.json"))

        XCTAssertNil(ipc.loadSpeakerRequest())
    }

    // MARK: - loadSpeakerCountRequest

    func testLoadSpeakerCountRequestValid() {
        let json = """
        {
            "version": 1,
            "timestamp": "2026-03-03T10:00:00",
            "meeting_title": "Retro"
        }
        """.data(using: .utf8)!
        try! json.write(to: tmpDir.appendingPathComponent("speaker_count_request.json"))

        let request = ipc.loadSpeakerCountRequest()

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.meetingTitle, "Retro")
        XCTAssertEqual(request?.version, 1)
    }

    func testLoadSpeakerCountRequestMissing() {
        XCTAssertNil(ipc.loadSpeakerCountRequest())
    }

    // MARK: - writeSpeakerCountResponse

    func testWriteSpeakerCountResponse() throws {
        try ipc.writeSpeakerCountResponse(4)

        let url = tmpDir.appendingPathComponent("speaker_count_response.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(decoded["version"] as? Int, 1)
        XCTAssertEqual(decoded["speaker_count"] as? Int, 4)
    }

    // MARK: - writeSpeakerResponse

    func testWriteSpeakerResponse() throws {
        try ipc.writeSpeakerResponse(["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"])

        let url = tmpDir.appendingPathComponent("speaker_response.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(decoded["version"] as? Int, 1)
        let speakers = decoded["speakers"] as! [String: String]
        XCTAssertEqual(speakers["SPEAKER_00"], "Alice")
        XCTAssertEqual(speakers["SPEAKER_01"], "Bob")
    }

    func testWriteSpeakerResponseEmpty() throws {
        try ipc.writeSpeakerResponse([:])

        let url = tmpDir.appendingPathComponent("speaker_response.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(decoded["version"] as? Int, 1)
        let speakers = decoded["speakers"] as! [String: String]
        XCTAssertTrue(speakers.isEmpty)
    }

    // MARK: - Write to missing directory throws

    func testWriteSpeakerCountResponseMissingDirThrows() {
        let missing = tmpDir.appendingPathComponent("nonexistent/subdir")
        let badIPC = IPCManager(baseDir: missing)
        XCTAssertThrowsError(try badIPC.writeSpeakerCountResponse(2))
    }

    func testWriteSpeakerResponseMissingDirThrows() {
        let missing = tmpDir.appendingPathComponent("nonexistent/subdir")
        let badIPC = IPCManager(baseDir: missing)
        XCTAssertThrowsError(try badIPC.writeSpeakerResponse(["A": "B"]))
    }

    // MARK: - Default init uses home directory

    func testDefaultInitUsesHomeDir() {
        let defaultIPC = IPCManager()
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        XCTAssertEqual(defaultIPC.baseDir, expected)
    }

    // MARK: - Load invalid speaker count request

    func testLoadSpeakerCountRequestInvalidJSON() {
        let garbage = "{{garbage}}".data(using: .utf8)!
        try! garbage.write(to: tmpDir.appendingPathComponent("speaker_count_request.json"))

        XCTAssertNil(ipc.loadSpeakerCountRequest())
    }

    // MARK: - Write overwrites existing file

    func testWriteSpeakerCountResponseOverwrites() throws {
        try ipc.writeSpeakerCountResponse(2)
        try ipc.writeSpeakerCountResponse(5)

        let url = tmpDir.appendingPathComponent("speaker_count_response.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(decoded["speaker_count"] as? Int, 5)
    }

    func testWriteSpeakerResponseOverwrites() throws {
        try ipc.writeSpeakerResponse(["S0": "Alice"])
        try ipc.writeSpeakerResponse(["S0": "Bob"])

        let url = tmpDir.appendingPathComponent("speaker_response.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let speakers = decoded["speakers"] as! [String: String]
        XCTAssertEqual(speakers["S0"], "Bob")
    }
}
