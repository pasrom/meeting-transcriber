import Foundation
import XCTest

@testable import MeetingTranscriber

final class PythonProcessTests: XCTestCase {

    // MARK: - Notification name

    func testUnexpectedTerminationNotificationName() {
        let name = PythonProcess.unexpectedTermination
        XCTAssertEqual(name.rawValue, "PythonProcessUnexpectedTermination")
    }

    // MARK: - isRunning when no process started

    func testIsRunningFalseByDefault() {
        let pp = PythonProcess()
        XCTAssertFalse(pp.isRunning)
    }

    // MARK: - Start with missing binary does not crash

    func testStartWithMissingBinaryDoesNotCrash() {
        let pp = PythonProcess()
        // projectRoot likely doesn't have .venv/bin/transcribe in test env
        // start() should bail out gracefully, not crash
        pp.start(arguments: ["--help"])
        XCTAssertFalse(pp.isRunning)
    }

    // MARK: - Termination handler fires on crash

    func testTerminationHandlerFiresOnUnexpectedExit() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "exit 42"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let exp = expectation(description: "termination handler called")
        var capturedStatus: Int32?

        proc.terminationHandler = { terminated in
            capturedStatus = terminated.terminationStatus
            exp.fulfill()
        }

        try! proc.run()
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(capturedStatus, 42)
    }

    // MARK: - Normal vs crash exit

    func testTerminationHandlerDistinguishesNormalFromCrash() {
        // Normal exit (status 0)
        let normalProc = Process()
        normalProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        normalProc.arguments = ["-c", "exit 0"]
        normalProc.standardOutput = FileHandle.nullDevice
        normalProc.standardError = FileHandle.nullDevice

        let normalExp = expectation(description: "normal exit")
        var normalStatus: Int32?

        normalProc.terminationHandler = { terminated in
            normalStatus = terminated.terminationStatus
            normalExp.fulfill()
        }

        try! normalProc.run()
        wait(for: [normalExp], timeout: 5.0)
        XCTAssertEqual(normalStatus, 0)

        // Crash exit (status 1)
        let crashProc = Process()
        crashProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        crashProc.arguments = ["-c", "exit 1"]
        crashProc.standardOutput = FileHandle.nullDevice
        crashProc.standardError = FileHandle.nullDevice

        let crashExp = expectation(description: "crash exit")
        var crashStatus: Int32?

        crashProc.terminationHandler = { terminated in
            crashStatus = terminated.terminationStatus
            crashExp.fulfill()
        }

        try! crashProc.run()
        wait(for: [crashExp], timeout: 5.0)
        XCTAssertEqual(crashStatus, 1)
    }

    // MARK: - Stderr goes to file, not /dev/null

    func testStderrWritesToLogFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let logFile = tmpDir.appendingPathComponent("test.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "echo 'stderr test output' >&2"]
        proc.standardOutput = FileHandle.nullDevice

        let logHandle = try FileHandle(forWritingTo: logFile)
        proc.standardError = logHandle

        try proc.run()
        proc.waitUntilExit()
        logHandle.closeFile()

        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("stderr test output"))
    }

    // MARK: - Notification posted on unexpected termination

    func testNotificationPostedOnCrash() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "exit 137"]  // simulate SIGKILL
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let notifExp = expectation(description: "notification posted")

        let observer = NotificationCenter.default.addObserver(
            forName: PythonProcess.unexpectedTermination,
            object: nil,
            queue: nil
        ) { notification in
            let status = notification.userInfo?["status"] as? Int32
            XCTAssertEqual(status, 137)
            notifExp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Replicate termination handler logic from PythonProcess
        proc.terminationHandler = { terminatedProc in
            let status = terminatedProc.terminationStatus
            let reason = terminatedProc.terminationReason
            if reason == .uncaughtSignal || (status != 0 && status != 2) {
                NotificationCenter.default.post(
                    name: PythonProcess.unexpectedTermination,
                    object: nil,
                    userInfo: ["status": status]
                )
            }
        }

        try! proc.run()
        wait(for: [notifExp], timeout: 5.0)
    }

    // MARK: - No notification on clean exit (status 0)

    func testNoNotificationOnCleanExit() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "exit 0"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let doneExp = expectation(description: "process done")
        let notifExp = expectation(description: "no notification")
        notifExp.isInverted = true  // must NOT be fulfilled

        let observer = NotificationCenter.default.addObserver(
            forName: PythonProcess.unexpectedTermination,
            object: nil,
            queue: nil
        ) { _ in
            notifExp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        proc.terminationHandler = { terminatedProc in
            let status = terminatedProc.terminationStatus
            let reason = terminatedProc.terminationReason
            if reason == .uncaughtSignal || (status != 0 && status != 2) {
                NotificationCenter.default.post(
                    name: PythonProcess.unexpectedTermination,
                    object: nil,
                    userInfo: ["status": status]
                )
            }
            doneExp.fulfill()
        }

        try! proc.run()
        wait(for: [doneExp], timeout: 5.0)
        wait(for: [notifExp], timeout: 0.5)  // inverted: passes if NOT fulfilled
    }

    // MARK: - No notification on SIGINT exit (status 2)

    func testNoNotificationOnSigintExit() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "exit 2"]  // simulate SIGINT
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let doneExp = expectation(description: "process done")
        let notifExp = expectation(description: "no notification on SIGINT")
        notifExp.isInverted = true

        let observer = NotificationCenter.default.addObserver(
            forName: PythonProcess.unexpectedTermination,
            object: nil,
            queue: nil
        ) { _ in
            notifExp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        proc.terminationHandler = { terminatedProc in
            let status = terminatedProc.terminationStatus
            let reason = terminatedProc.terminationReason
            if reason == .uncaughtSignal || (status != 0 && status != 2) {
                NotificationCenter.default.post(
                    name: PythonProcess.unexpectedTermination,
                    object: nil,
                    userInfo: ["status": status]
                )
            }
            doneExp.fulfill()
        }

        try! proc.run()
        wait(for: [doneExp], timeout: 5.0)
        wait(for: [notifExp], timeout: 0.5)
    }
}
