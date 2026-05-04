import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Permissions")

enum Permissions {
    /// Check if Screen Recording permission is granted.
    static func checkScreenRecording() -> Bool {
        let granted = PermissionHealthCheck.checkScreenRecordingLive() == .healthy
        if !granted {
            logger.warning("permission_denied resource=screen_recording — required for meeting detection")
        }
        return granted
    }

    static func ensureMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                logger.warning("permission_denied resource=microphone status=user_denied_prompt")
            }
            return granted
        }
        logger.warning(
            "permission_denied resource=microphone status=\(status.rawValue, privacy: .public)",
        )
        return false
    }

    private static let accessibilityPromptLock = OSAllocatedUnfairLock(initialState: false)
    // swiftlint:disable:next unused_declaration
    static func ensureAccessibilityAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        let alreadyPrompted = accessibilityPromptLock.withLock { prompted -> Bool in
            if prompted { return true }
            prompted = true
            return false
        }
        guard !alreadyPrompted else {
            logger.warning("permission_denied resource=accessibility status=already_prompted")
            return false
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        if !granted {
            logger.warning("permission_denied resource=accessibility status=user_denied_prompt")
        }
        return granted
    }
}
