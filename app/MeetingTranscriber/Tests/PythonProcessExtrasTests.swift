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

    // MARK: - findProjectRoot: pyproject in same directory as binary

    func testFindProjectRootSameDir() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("samedir-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("pyproject.toml").path,
            contents: nil
        )

        // Binary in same dir as pyproject.toml
        let fakeExe = tmpDir.appendingPathComponent("binary")
        let result = PythonProcess.findProjectRoot(from: fakeExe)
        XCTAssertEqual(result, tmpDir.path)
    }

    // MARK: - findProjectRoot: max depth limit (10 levels)

    func testFindProjectRootMaxDepth() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deep-test-\(UUID().uuidString)")
        // Create 12 levels deep — pyproject.toml at root, binary 12 levels down
        // findProjectRoot walks up max 10 levels, so it should NOT find it
        var deep = tmpDir
        for i in 0..<12 {
            deep = deep.appendingPathComponent("level\(i)")
        }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("pyproject.toml").path,
            contents: nil
        )

        let fakeExe = deep.appendingPathComponent("binary")
        let result = PythonProcess.findProjectRoot(from: fakeExe)
        // 12 levels up > 10 max → should not find it
        XCTAssertNil(result)
    }

    // MARK: - Crash-loop boundary: exactly at window edge

    func testCrashesExactlyAtWindowEdge() {
        let pp = PythonProcess()
        let now = Date()
        // Two crashes exactly at the window boundary (300s ago)
        pp.recordCrash(at: now.addingTimeInterval(-300))
        pp.recordCrash(at: now.addingTimeInterval(-299))
        // Third crash now — the first crash is AT the cutoff boundary
        // cutoff = now - 300s, removeAll { $0 < cutoff } means $0 == cutoff survives
        pp.recordCrash(at: now)
        // All 3 should be in window (first one is exactly at cutoff, not before)
        XCTAssertTrue(pp.crashLoopDetected)
    }

    func testCrashesJustOutsideWindow() {
        let pp = PythonProcess()
        let now = Date()
        // Two crashes just outside the window (301s ago)
        pp.recordCrash(at: now.addingTimeInterval(-301))
        pp.recordCrash(at: now.addingTimeInterval(-301))
        // Third crash now — old ones should be pruned
        pp.recordCrash(at: now)
        XCTAssertFalse(pp.crashLoopDetected)
    }

    // MARK: - Two crashes then reset then two more — no loop

    func testResetBetweenCrashBursts() {
        let pp = PythonProcess()
        let now = Date()
        pp.recordCrash(at: now)
        pp.recordCrash(at: now.addingTimeInterval(1))
        XCTAssertFalse(pp.crashLoopDetected)

        pp.resetCrashLoop()

        pp.recordCrash(at: now.addingTimeInterval(2))
        pp.recordCrash(at: now.addingTimeInterval(3))
        // Only 2 crashes since reset, not 3
        XCTAssertFalse(pp.crashLoopDetected)
    }
}
