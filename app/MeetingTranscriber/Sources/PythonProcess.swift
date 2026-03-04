import ApplicationServices
import AVFoundation
import Foundation

/// Manages the lifecycle of the `transcribe --watch` Python process.
final class PythonProcess {
    private var process: Process?
    let projectRoot: String

    /// Posted when the Python process terminates unexpectedly.
    static let unexpectedTermination = Notification.Name("PythonProcessUnexpectedTermination")

    // Crash-loop protection
    private var crashTimestamps: [Date] = []
    private static let maxCrashes = 3
    private static let crashWindow: TimeInterval = 300  // 5 minutes
    private(set) var crashLoopDetected = false

    private static var logFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcriber.log")
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Whether the app is running from a self-contained .app bundle
    /// (with embedded Python env) vs. dev mode (using .venv/).
    var isBundled: Bool {
        guard let res = Bundle.main.resourcePath else { return false }
        return FileManager.default.fileExists(
            atPath: (res as NSString).appendingPathComponent("python-env"))
    }

    /// Open a log file for appending, creating it if needed. Falls back to /dev/null.
    static func openLogHandle(at url: URL) -> FileHandle {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            return handle
        }
        // Create the file and retry
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            return handle
        }
        return .nullDevice
    }

    init() {
        // 1. TRANSCRIBER_ROOT env var (set by run_app.sh)
        // 2. Walk up from executable looking for pyproject.toml
        if let envRoot = ProcessInfo.processInfo.environment["TRANSCRIBER_ROOT"] {
            projectRoot = envRoot
        } else {
            projectRoot = Self.findProjectRoot(from: nil) ?? FileManager.default.currentDirectoryPath
        }
    }

    /// Record a crash and update crash-loop detection state.
    func recordCrash(at date: Date = Date()) {
        crashTimestamps.append(date)
        let cutoff = date.addingTimeInterval(-Self.crashWindow)
        crashTimestamps.removeAll { $0 < cutoff }
        if crashTimestamps.count >= Self.maxCrashes {
            crashLoopDetected = true
        }
    }

    /// Reset crash-loop state so the process can be started again.
    func resetCrashLoop() {
        crashTimestamps.removeAll()
        crashLoopDetected = false
    }

    /// Request microphone permission so the child Python process can record.
    /// Must be called from the app process — child processes can't trigger the dialog.
    static func ensureMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        // .denied or .restricted
        return false
    }

    /// Check (and prompt for) Accessibility permission.
    /// Required for mute-button detection in Teams via AXUIElement.
    /// macOS TCC checks the "responsible process" (this app), not the
    /// Python subprocess, so the prompt must come from here.
    static func ensureAccessibilityAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start(arguments: [String] = ["--watch"]) {
        guard process == nil || process?.isRunning == false else { return }

        if crashLoopDetected {
            print("Refusing to start: crash loop detected (\(Self.maxCrashes) crashes in \(Int(Self.crashWindow))s)")
            return
        }

        let proc = Process()
        var env = ProcessInfo.processInfo.environment

        if isBundled {
            // ── Bundle mode: use embedded Python env from Resources/ ──
            let res = Bundle.main.resourcePath!
            let pythonEnv = (res as NSString).appendingPathComponent("python-env")
            let pythonBin = (pythonEnv as NSString).appendingPathComponent("bin")
            let transcribePath = (pythonBin as NSString).appendingPathComponent("transcribe")

            guard FileManager.default.fileExists(atPath: transcribePath) else {
                print("Error: transcribe not found in bundle at \(transcribePath)")
                return
            }

            proc.executableURL = URL(fileURLWithPath: transcribePath)

            env["VIRTUAL_ENV"] = pythonEnv
            env["PATH"] = "\(pythonBin):\(env["PATH"] ?? "/usr/bin")"
            env["MEETING_TRANSCRIBER_BUNDLED"] = "1"

            // audiotap binary from bundle
            let audiotapPath = (res as NSString).appendingPathComponent("audiotap")
            if FileManager.default.fileExists(atPath: audiotapPath) {
                env["AUDIOTAP_BINARY"] = audiotapPath
            }
        } else {
            // ── Dev mode: use .venv/ from project root ──
            let venvBin = (projectRoot as NSString).appendingPathComponent(".venv/bin")
            let transcribePath = (venvBin as NSString).appendingPathComponent("transcribe")

            guard FileManager.default.fileExists(atPath: transcribePath) else {
                print("Error: transcribe binary not found at \(transcribePath)")
                return
            }

            proc.executableURL = URL(fileURLWithPath: transcribePath)
            proc.currentDirectoryURL = URL(fileURLWithPath: projectRoot)

            env["VIRTUAL_ENV"] = (projectRoot as NSString).appendingPathComponent(".venv")
            env["PATH"] = "\(venvBin):\(env["PATH"] ?? "/usr/bin")"
        }

        proc.arguments = arguments

        // Remove Claude Code session marker so protocol generation can spawn claude CLI
        env.removeValue(forKey: "CLAUDECODE")
        // Inject HuggingFace token from Keychain for speaker diarization
        if let hfToken = KeychainHelper.read(key: "HF_TOKEN") {
            env["HF_TOKEN"] = hfToken
        }
        proc.environment = env

        // Pipe stdout + stderr to log file for debugging
        let logHandle = Self.openLogHandle(at: Self.logFileURL)
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        // Detect unexpected termination (crash, signal)
        proc.terminationHandler = { [weak self] terminatedProc in
            let status = terminatedProc.terminationStatus
            let reason = terminatedProc.terminationReason
            if reason == .uncaughtSignal || (status != 0 && status != 2) {
                // status 2 = SIGINT (normal shutdown via stop())
                print("Python process terminated unexpectedly: status=\(status), reason=\(reason)")

                // Track crash for crash-loop detection
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.recordCrash()
                    if self.crashLoopDetected {
                        print("Crash loop detected: \(Self.maxCrashes) crashes in \(Int(Self.crashWindow))s")
                    }
                }

                NotificationCenter.default.post(
                    name: PythonProcess.unexpectedTermination,
                    object: nil,
                    userInfo: [
                        "status": status,
                        "crashLoop": self?.crashLoopDetected ?? false,
                    ]
                )
            }
            DispatchQueue.main.async {
                self?.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            print("Failed to start transcribe process: \(error)")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }

        // SIGINT → Python catches KeyboardInterrupt for graceful shutdown
        proc.interrupt()

        // Give it 5 seconds, then force terminate
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let proc = self.process, proc.isRunning else { return }
            proc.terminate()
        }
    }

    // MARK: - Project Root Discovery

    static func findProjectRoot(from startURL: URL? = nil) -> String? {
        let start = startURL ?? URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        var dir = start.deletingLastPathComponent()

        for _ in 0..<10 {
            let pyproject = dir.appendingPathComponent("pyproject.toml")
            if FileManager.default.fileExists(atPath: pyproject.path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
