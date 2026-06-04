// `@preconcurrency`: ApplicationServices AX globals + AVFoundation
// types lack Sendable annotations — same gaps as Permissions.swift /
// AudioMixer.swift; preemptively guarded.
@preconcurrency import ApplicationServices
import AudioTapLib
@preconcurrency import AVFoundation
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

    /// Peak amplitude (linear, 0…1) below which a mic stream is treated as silence even
    /// if buffers are flowing — a working mic in any real environment exceeds the
    /// noise-floor by orders of magnitude. ~−80 dBFS.
    static let silentMicPeakThreshold: Float = 0.0001

    /// Returns the maximum absolute sample amplitude in `buffer` on channel 0, normalized
    /// to 0…1. Unknown sample formats fall back to `1.0` so they pass the silence check —
    /// preserves pre-cherry-pick behavior (any buffer = live).
    static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let channelData = buffer.floatChannelData {
            var peak: Float = 0
            for sample in UnsafeBufferPointer(start: channelData[0], count: frames) {
                let abs = Swift.abs(sample)
                if abs > peak { peak = abs }
            }
            return peak
        }
        if let channelData = buffer.int16ChannelData {
            var peak: Float = 0
            let scale = 1.0 / Float(Int16.max)
            for sample in UnsafeBufferPointer(start: channelData[0], count: frames) {
                let abs = Swift.abs(Float(sample)) * scale
                if abs > peak { peak = abs }
            }
            return peak
        }
        return 1.0
    }

    /// Thread-safe mic probe stats (tap callback runs on audio thread).
    private final class BufferCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var maxPeak: Float = 0
        func record(buffer: AVAudioPCMBuffer) {
            let peak = PermissionHealthCheck.peakAmplitude(of: buffer)
            lock.lock()
            count += 1
            if peak > maxPeak { maxPeak = peak }
            lock.unlock()
        }

        func snapshot() -> (count: Int, maxPeak: Float) {
            lock.lock(); defer { lock.unlock() }
            return (count, maxPeak)
        }
    }

    /// Maximum time to wait for the mic probe to observe a non-silent sample.
    static let probeTimeout: TimeInterval = 0.5
    /// Poll interval while waiting for the probe to confirm a healthy signal.
    static let probePollInterval: TimeInterval = 0.02

    static func probeMicrophone() async -> Bool {
        // No input device available (e.g. Mac Mini server without mic hardware) —
        // accessing AVAudioEngine.inputNode would throw an uncatchable NSException.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            debugLog("probeMicrophone: no input device available")
            return false
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // inputFormat reflects what the hardware actually delivers; outputFormat can report
        // a degenerate (sampleRate=0) format when nothing is attached downstream, which
        // would false-fail the guard below.
        let format = inputNode.inputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            debugLog("probeMicrophone: invalid format sampleRate=\(format.sampleRate) " +
                "channels=\(format.channelCount)")
            return false
        }

        let counter = BufferCounter()
        do {
            // safeInstallTap: a device change mid-probe could make installTap
            // raise an uncatchable NSException (issue #379); treat that as a
            // failed probe rather than an abort.
            try inputNode.safeInstallTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                if buffer.frameLength > 0 { counter.record(buffer: buffer) }
            }
        } catch {
            debugLog("probeMicrophone: installTap failed: \(error.localizedDescription)")
            return false
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            debugLog("probeMicrophone: engine.start() threw: \(error.localizedDescription)")
            return false
        }

        let (stats, elapsedMs) = await waitForProbeSignal(
            deadline: Date().addingTimeInterval(probeTimeout),
            threshold: Self.silentMicPeakThreshold,
            pollInterval: Self.probePollInterval,
            snapshot: counter.snapshot,
        )

        engine.stop()
        inputNode.removeTap(onBus: 0)

        debugLog("probeMicrophone: buffers=\(stats.count) peak=\(stats.maxPeak) elapsed=\(elapsedMs)ms " +
            "sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        // swiftformat:disable:next preferIsEmpty
        return stats.count > 0 && stats.maxPeak > Self.silentMicPeakThreshold // swiftlint:disable:this empty_count
    }

    /// Polls `snapshot` until peak crosses `threshold` (healthy) or `now()` passes `deadline`
    /// (broken). Polling on `count > 0` would exit on the first warm-up buffer — which is
    /// commonly all-zeros — and falsely report `.broken`.
    ///
    /// `now` and `sleep` are injected so unit tests can drive the loop with a virtual clock.
    static func waitForProbeSignal(
        deadline: Date,
        threshold: Float,
        pollInterval: TimeInterval,
        snapshot: @Sendable () -> (count: Int, maxPeak: Float),
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (TimeInterval) async -> Void = { duration in
            try? await Task.sleep(for: .seconds(duration))
        },
    ) async -> (stats: (count: Int, maxPeak: Float), elapsedMs: Int) {
        let startedAt = now()
        while now() < deadline {
            if snapshot().maxPeak > threshold { break }
            await sleep(pollInterval)
        }
        let elapsedMs = Int(now().timeIntervalSince(startedAt) * 1000)
        return (snapshot(), elapsedMs)
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
