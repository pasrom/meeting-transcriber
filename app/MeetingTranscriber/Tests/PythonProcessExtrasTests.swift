import Foundation
import XCTest

@testable import MeetingTranscriber

final class PythonProcessExtrasTests: XCTestCase {

    // MARK: - recordCrash

    func testSingleCrashNoLoop() {
        let pp = PythonProcess()
        pp.recordCrash()
        XCTAssertFalse(pp.crashLoopDetected)
    }

    func testThreeCrashesTriggersLoop() {
        let pp = PythonProcess()
        let now = Date()
        pp.recordCrash(at: now)
        pp.recordCrash(at: now.addingTimeInterval(1))
        pp.recordCrash(at: now.addingTimeInterval(2))
        XCTAssertTrue(pp.crashLoopDetected)
    }

    func testOldCrashesExpire() {
        let pp = PythonProcess()
        let now = Date()
        // Two crashes 6 minutes ago — outside the 5-minute window
        pp.recordCrash(at: now.addingTimeInterval(-360))
        pp.recordCrash(at: now.addingTimeInterval(-350))
        // One crash now — only 1 in window
        pp.recordCrash(at: now)
        XCTAssertFalse(pp.crashLoopDetected)
    }

    func testResetClearsTimestamps() {
        let pp = PythonProcess()
        let now = Date()
        pp.recordCrash(at: now)
        pp.recordCrash(at: now.addingTimeInterval(1))
        pp.recordCrash(at: now.addingTimeInterval(2))
        XCTAssertTrue(pp.crashLoopDetected)

        pp.resetCrashLoop()
        XCTAssertFalse(pp.crashLoopDetected)

        // One more crash should NOT re-trigger the loop
        pp.recordCrash()
        XCTAssertFalse(pp.crashLoopDetected)
    }

    // MARK: - findProjectRoot

    func testFindProjectRootFromNestedDir() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-test-\(UUID().uuidString)")
        let nested = tmpDir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Place pyproject.toml at the root
        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("pyproject.toml").path,
            contents: nil
        )

        // Fake executable inside nested dir
        let fakeExe = nested.appendingPathComponent("binary")
        let result = PythonProcess.findProjectRoot(from: fakeExe)

        XCTAssertEqual(result, tmpDir.path)
    }

    func testFindProjectRootMissing() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeExe = tmpDir.appendingPathComponent("binary")
        let result = PythonProcess.findProjectRoot(from: fakeExe)

        XCTAssertNil(result)
    }
}
