import ApplicationServices
import AVFoundation
import CoreGraphics
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PermissionHealthCheck")

enum PermissionStatus: Equatable {
    case healthy
    case denied
    case broken
    case notDetermined
}

enum PermissionProblem: Equatable {
    case screenRecordingDenied
    case screenRecordingBroken
    case microphoneDenied
    case microphoneBroken
    case accessibilityDenied
    case accessibilityBroken

    var permissionName: String {
        switch self {
        case .screenRecordingDenied, .screenRecordingBroken: "Screen Recording"
        case .microphoneDenied, .microphoneBroken: "Microphone"
        case .accessibilityDenied, .accessibilityBroken: "Accessibility"
        }
    }

    var isBroken: Bool {
        switch self {
        case .screenRecordingBroken, .microphoneBroken, .accessibilityBroken: true
        case .screenRecordingDenied, .microphoneDenied, .accessibilityDenied: false
        }
    }

    var description: String {
        isBroken
            ? "\(permissionName) looks enabled but isn't working — toggle it off and on in System Settings"
            : "\(permissionName) permission denied"
    }
}

struct HealthCheckResult: Equatable {
    let screenRecording: PermissionStatus
    let microphone: PermissionStatus
    let accessibility: PermissionStatus

    init(
        screenRecording: PermissionStatus,
        microphone: PermissionStatus,
        accessibility: PermissionStatus = .healthy,
    ) {
        self.screenRecording = screenRecording
        self.microphone = microphone
        self.accessibility = accessibility
    }

    var problems: [PermissionProblem] {
        var result: [PermissionProblem] = []
        switch screenRecording {
        case .denied: result.append(.screenRecordingDenied)
        case .broken: result.append(.screenRecordingBroken)
        default: break
        }
        switch microphone {
        case .denied: result.append(.microphoneDenied)
        case .broken: result.append(.microphoneBroken)
        default: break
        }
        switch accessibility {
        case .denied: result.append(.accessibilityDenied)
        case .broken: result.append(.accessibilityBroken)
        default: break
        }
        return result
    }

    var isHealthy: Bool {
        problems.isEmpty
    }

    var notificationBody: String {
        problems.map(\.description).joined(separator: "\n")
    }
}

enum PermissionHealthCheck {
    // MARK: - Screen Recording (pure, testable)

    /// Pure decision function: combines the TCC system verdict with a window-title probe.
    ///
    /// - `systemAllowed`: whether macOS says the process has the Screen Recording entitlement
    ///   (via `CGPreflightScreenCaptureAccess()` or equivalent).
    /// - `hasForeignWithTitle`: whether `CGWindowListCopyWindowInfo` returned at least one
    ///   window from another process that has a non-empty `kCGWindowName`.
    ///
    /// Outcomes:
    /// - `denied`: system says no
    /// - `healthy`: system says yes AND we can read foreign window titles
    /// - `broken`: system says yes BUT we cannot read any foreign window titles (TCC mismatch)
    static func checkScreenRecording(
        systemAllowed: Bool,
        hasForeignWithTitle: Bool,
    ) -> PermissionStatus {
        if !systemAllowed { return .denied }
        return hasForeignWithTitle ? .healthy : .broken
    }

    /// Parses a raw window list and reports whether any foreign window has a non-empty title.
    static func hasForeignWindowWithTitle(
        windowList: [[String: Any]]?, // swiftlint:disable:this discouraged_optional_collection
        ownPID: Int32,
    ) -> Bool {
        guard let windows = windowList else { return false }
        return windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid != ownPID
            else { return false }
            let name = info[kCGWindowName as String] as? String
            return name != nil && !(name?.isEmpty ?? true)
        }
    }

    static func checkScreenRecordingLive() -> PermissionStatus {
        // CGPreflightScreenCaptureAccess does NOT trigger the TCC prompt — it only reports status.
        let systemAllowed = CGPreflightScreenCaptureAccess()

        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID,
        ) as? [[String: Any]]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windowCount = list?.count ?? -1
        let foreignCount = (list ?? []).count { info in
            (info[kCGWindowOwnerPID as String] as? Int32) != ownPID
        }
        let hasForeignTitle = hasForeignWindowWithTitle(windowList: list, ownPID: ownPID)

        let result = checkScreenRecording(
            systemAllowed: systemAllowed,
            hasForeignWithTitle: hasForeignTitle,
        )
        debugLog("checkScreenRecordingLive: systemAllowed=\(systemAllowed) ownPID=\(ownPID) " +
            "windows=\(windowCount) foreign=\(foreignCount) hasForeignTitle=\(hasForeignTitle) → \(result)")
        return result
    }

    // MARK: - Microphone (pure, testable)

    static func checkMicrophone(
        authStatus: AVAuthorizationStatus,
        probeSucceeds: Bool,
    ) -> PermissionStatus {
        switch authStatus {
        case .notDetermined:
            return .notDetermined

        case .denied, .restricted:
            return .denied

        case .authorized:
            return probeSucceeds ? .healthy : .broken

        @unknown default:
            return .denied
        }
    }

    /// Thread-safe counter for mic probe buffer arrival (tap callback runs on audio thread).
    private final class BufferCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock(); count += 1; lock.unlock()
        }

        func value() -> Int {
            lock.lock(); defer { lock.unlock() }; return count
        }
    }

    /// Maximum time to wait for the first mic buffer to arrive.
    static let probeTimeout: TimeInterval = 0.5
    /// Poll interval while waiting for the first buffer.
    static let probePollInterval: TimeInterval = 0.02

    static func probeMicrophone() async -> Bool {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            debugLog("probeMicrophone: invalid format sampleRate=\(format.sampleRate) " +
                "channels=\(format.channelCount)")
            return false
        }

        let counter = BufferCounter()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if buffer.frameLength > 0 { counter.increment() }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            debugLog("probeMicrophone: engine.start() threw: \(error.localizedDescription)")
            return false
        }

        // Poll until the first buffer arrives or the timeout elapses.
        let deadline = Date().addingTimeInterval(probeTimeout)
        let startedAt = Date()
        while counter.value() == 0, Date() < deadline {
            try? await Task.sleep(for: .seconds(probePollInterval))
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let buffersSeen = counter.value()

        engine.stop()
        inputNode.removeTap(onBus: 0)

        debugLog("probeMicrophone: buffers=\(buffersSeen) elapsed=\(elapsedMs)ms " +
            "sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        return buffersSeen > 0
    }

    static func checkMicrophoneLive() async -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != .authorized {
            let r = checkMicrophone(authStatus: status, probeSucceeds: false)
            debugLog("checkMicrophoneLive: authStatus=\(status.rawValue) probe=skipped → \(r)")
            return r
        }
        let probe = await probeMicrophone()
        let r = checkMicrophone(authStatus: status, probeSucceeds: probe)
        debugLog("checkMicrophoneLive: authStatus=authorized probe=\(probe) → \(r)")
        return r
    }

    // MARK: - Accessibility (pure, testable)

    /// Pure decision function for Accessibility permission state.
    ///
    /// - `trusted`: whether `AXIsProcessTrusted()` returns true.
    /// - `probeSucceeds`: whether a concrete AX API call (e.g. reading the focused app of
    ///   `AXUIElementCreateSystemWide`) returns `.success`.
    static func checkAccessibility(
        trusted: Bool,
        probeSucceeds: Bool,
    ) -> PermissionStatus {
        if !trusted { return .denied }
        return probeSucceeds ? .healthy : .broken
    }

    /// Probes the Accessibility API with a lightweight system-wide call.
    /// Returns true if the call succeeds (and we either get a valid attribute or `noValue`).
    static func probeAccessibility() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &value,
        )
        // .success: got the focused app. .noValue: no focused app right now, but the API worked.
        // Any other error (e.g. .cannotComplete, .apiDisabled) indicates AX isn't actually granted.
        return err == .success || err == .noValue
    }

    static func checkAccessibilityLive() -> PermissionStatus {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            debugLog("checkAccessibilityLive: trusted=false → denied")
            return .denied
        }
        let probe = probeAccessibility()
        let r = checkAccessibility(trusted: trusted, probeSucceeds: probe)
        debugLog("checkAccessibilityLive: trusted=true probe=\(probe) → \(r)")
        return r
    }

    // MARK: - Overall Health

    static func overallHealth(
        screenRecording: PermissionStatus,
        microphone: PermissionStatus,
        accessibility: PermissionStatus = .healthy,
    ) -> HealthCheckResult {
        HealthCheckResult(
            screenRecording: screenRecording,
            microphone: microphone,
            accessibility: accessibility,
        )
    }

    static func runLive() async -> HealthCheckResult {
        let sr = checkScreenRecordingLive()
        let mic = await checkMicrophoneLive()
        let ax = checkAccessibilityLive()
        let result = overallHealth(screenRecording: sr, microphone: mic, accessibility: ax)
        if !result.isHealthy {
            logger.warning("Permission health check failed: \(result.problems)")
        }
        return result
    }

    // MARK: - Debug Logging

    /// Appender for `/tmp/mt-permission.log` — independent of `os_log`, which is not visible
    /// for ad-hoc signed dev bundles. The log file is truncated on first write per process
    /// (via the one-shot `init` of the static instance) so it cannot grow unbounded across
    /// long-running sessions.
    private final class DebugLogFile: @unchecked Sendable {
        private let path: String
        private let formatter: ISO8601DateFormatter
        private let lock = NSLock()

        init(path: String) {
            self.path = path
            self.formatter = ISO8601DateFormatter()
            try? FileManager.default.removeItem(atPath: path)
        }

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            let payload = "[\(formatter.string(from: Date()))] \(line)\n"
            guard let data = payload.data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: path)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static let debugLogFile = DebugLogFile(path: "/tmp/mt-permission.log")

    static func debugLog(_ line: String) {
        debugLogFile.append(line)
    }
}
