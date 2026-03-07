import XCTest

@testable import MeetingTranscriber

final class DiarizationProcessTests: XCTestCase {

    // MARK: - JSON Parsing

    func testParseValidOutput() throws {
        let json = """
            {
              "segments": [
                {"start": 0.0, "end": 5.2, "speaker": "SPEAKER_00"},
                {"start": 5.2, "end": 10.1, "speaker": "SPEAKER_01"},
                {"start": 10.1, "end": 15.0, "speaker": "SPEAKER_00"}
              ],
              "embeddings": {
                "SPEAKER_00": [0.1, 0.2, 0.3],
                "SPEAKER_01": [0.4, 0.5, 0.6]
              },
              "auto_names": {
                "SPEAKER_00": "Alice"
              },
              "speaking_times": {
                "SPEAKER_00": 10.1,
                "SPEAKER_01": 4.9
              }
            }
            """
        let data = Data(json.utf8)
        let result = try DiarizationProcess.parseOutput(data)

        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result.segments[0].start, 0.0)
        XCTAssertEqual(result.segments[0].end, 5.2)
        XCTAssertEqual(result.segments[1].speaker, "SPEAKER_01")

        XCTAssertEqual(result.speakingTimes["SPEAKER_00"], 10.1)
        XCTAssertEqual(result.speakingTimes["SPEAKER_01"], 4.9)

        XCTAssertEqual(result.autoNames["SPEAKER_00"], "Alice")
        XCTAssertNil(result.autoNames["SPEAKER_01"])
    }

    func testParseEmptySegments() throws {
        let json = """
            {"segments": [], "embeddings": {}, "auto_names": {}, "speaking_times": {}}
            """
        let result = try DiarizationProcess.parseOutput(Data(json.utf8))
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakingTimes.isEmpty)
    }

    func testParseInvalidJSON() {
        let data = Data("not json".utf8)
        XCTAssertThrowsError(try DiarizationProcess.parseOutput(data))
    }

    func testParseMissingFields() throws {
        // segments with missing fields should be skipped
        let json = """
            {"segments": [{"start": 0.0}, {"start": 1.0, "end": 2.0, "speaker": "A"}]}
            """
        let result = try DiarizationProcess.parseOutput(Data(json.utf8))
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].speaker, "A")
    }

    // MARK: - Availability

    func testNotAvailableWithNonexistentPaths() {
        let proc = DiarizationProcess(
            pythonPath: URL(fileURLWithPath: "/nonexistent/python"),
            scriptPath: URL(fileURLWithPath: "/nonexistent/diarize.py")
        )
        XCTAssertFalse(proc.isAvailable)
    }

    func testAvailableWithProjectPaths() {
        // Verify dev-mode fallback paths exist
        guard let root = Permissions.findProjectRoot(from: nil) else {
            // Skip if not running from project (e.g. CI)
            return
        }
        let pythonPath = URL(fileURLWithPath: root).appendingPathComponent(".venv/bin/python")
        let scriptPath = URL(fileURLWithPath: root).appendingPathComponent("tools/diarize/diarize.py")

        let proc = DiarizationProcess(pythonPath: pythonPath, scriptPath: scriptPath)

        // Both files should exist in the project
        let pythonExists = FileManager.default.fileExists(atPath: pythonPath.path)
        let scriptExists = FileManager.default.fileExists(atPath: scriptPath.path)
        XCTAssertEqual(proc.isAvailable, pythonExists && scriptExists)
    }

    func testDefaultInitUsesDevFallback() {
        // When running from project (not bundle), default init should find dev paths
        let proc = DiarizationProcess()
        // In test environment, bundle won't have python-diarize,
        // so it should fall back to project paths if they exist
        if let root = Permissions.findProjectRoot(from: nil) {
            let venvExists = FileManager.default.fileExists(
                atPath: root + "/.venv/bin/python")
            let scriptExists = FileManager.default.fileExists(
                atPath: root + "/tools/diarize/diarize.py")
            if venvExists && scriptExists {
                XCTAssertTrue(proc.isAvailable,
                    "DiarizationProcess should be available in dev mode with venv + script")
            }
        }
    }

    // MARK: - Speaker Assignment

    func testAssignSpeakers() {
        let transcript = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
            TimestampedSegment(start: 5, end: 10, text: "World"),
            TimestampedSegment(start: 10, end: 15, text: "Bye"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 6, speaker: "Alice"),
                .init(start: 6, end: 15, speaker: "Bob"),
            ],
            speakingTimes: ["Alice": 6, "Bob": 9],
            autoNames: [:]
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        XCTAssertEqual(result[0].speaker, "Alice")  // 0-5 overlaps Alice (0-6)
        XCTAssertEqual(result[1].speaker, "Bob")     // 5-10: 1s Alice, 4s Bob → Bob
        XCTAssertEqual(result[2].speaker, "Bob")     // 10-15 fully Bob
    }

    func testAssignSpeakersNoOverlap() {
        let transcript = [
            TimestampedSegment(start: 100, end: 105, text: "Late"),
        ]

        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "Alice"),
            ],
            speakingTimes: ["Alice": 5],
            autoNames: [:]
        )

        let result = DiarizationProcess.assignSpeakers(
            transcript: transcript, diarization: diarization
        )

        XCTAssertEqual(result[0].speaker, "UNKNOWN")
    }

    func testAssignSpeakersEmpty() {
        let result = DiarizationProcess.assignSpeakers(
            transcript: [],
            diarization: DiarizationResult(segments: [], speakingTimes: [:], autoNames: [:])
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Pipe Deadlock (C1+C2)

    func testRunWithLargeOutputDoesNotDeadlock() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarize_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptPath = tmpDir.appendingPathComponent("big_output.py")
        // Generate >64KB of JSON output (512-dim embeddings x 200 speakers)
        let script = """
            import json, sys
            segments = [{"start": float(i), "end": float(i+1), "speaker": f"SPEAKER_{i:02d}"}
                        for i in range(200)]
            embeddings = {f"SPEAKER_{i:02d}": [0.1] * 512 for i in range(200)}
            result = {"segments": segments, "embeddings": embeddings,
                      "speaking_times": {}, "auto_names": {}}
            json.dump(result, sys.stdout)
            """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        let proc = DiarizationProcess(
            pythonPath: URL(fileURLWithPath: "/usr/bin/python3"),
            scriptPath: scriptPath
        )

        // This would deadlock before the fix
        let result = try await proc.run(
            audioPath: scriptPath, // dummy, script ignores it
            numSpeakers: nil,
            meetingTitle: "Test"
        )
        XCTAssertGreaterThan(result.segments.count, 100)
    }
}
