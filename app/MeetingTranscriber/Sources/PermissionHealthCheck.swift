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
}

struct HealthCheckResult: Equatable {
    let screenRecording: PermissionStatus
    let microphone: PermissionStatus

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
        return result
    }

    var isHealthy: Bool {
        screenRecording != .denied && screenRecording != .broken
            && microphone != .denied && microphone != .broken
    }

    var notificationBody: String {
        let parts = problems.map { problem -> String in
            switch problem {
            case .screenRecordingDenied:
                "Screen Recording permission denied"

            case .screenRecordingBroken:
                "Screen Recording permission appears broken — please reset in System Settings"

            case .microphoneDenied:
                "Microphone permission denied"

            case .microphoneBroken:
                "Microphone permission appears broken — please reset in System Settings"
            }
        }
        return parts.joined(separator: "\n")
    }
}

enum PermissionHealthCheck {
    // MARK: - Screen Recording (pure, testable)

    static func checkScreenRecording(
        windowList: [[String: Any]]?, // swiftlint:disable:this discouraged_optional_collection
        ownPID: Int32,
    ) -> PermissionStatus {
        guard let windows = windowList else { return .denied }

        let foreignWithTitle = windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid != ownPID
            else { return false }
            let name = info[kCGWindowName as String] as? String
            return name != nil && !(name?.isEmpty ?? true)
        }

        if foreignWithTitle { return .healthy }
        return .broken
    }

    static func checkScreenRecordingLive() -> PermissionStatus {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID,
        ) as? [[String: Any]]
        return checkScreenRecording(
            windowList: list,
            ownPID: ProcessInfo.processInfo.processIdentifier,
        )
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

    static func probeMicrophone() async -> Bool {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            return false
        }

        var gotSamples = false
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if buffer.frameLength > 0 { gotSamples = true }
        }

        do {
            try engine.start()
            try? await Task.sleep(for: .milliseconds(50))
            engine.stop()
            inputNode.removeTap(onBus: 0)
            return gotSamples
        } catch {
            logger.warning("Mic probe failed: \(error.localizedDescription)")
            return false
        }
    }

    static func checkMicrophoneLive() async -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != .authorized { return checkMicrophone(authStatus: status, probeSucceeds: false) }
        return await checkMicrophone(authStatus: status, probeSucceeds: probeMicrophone())
    }

    // MARK: - Overall Health

    static func overallHealth(
        screenRecording: PermissionStatus,
        microphone: PermissionStatus,
    ) -> HealthCheckResult {
        HealthCheckResult(screenRecording: screenRecording, microphone: microphone)
    }

    static func runLive() async -> HealthCheckResult {
        let sr = checkScreenRecordingLive()
        let mic = await checkMicrophoneLive()
        let result = overallHealth(screenRecording: sr, microphone: mic)
        if !result.isHealthy {
            logger.warning("Permission health check failed: \(result.problems)")
        }
        return result
    }
}
