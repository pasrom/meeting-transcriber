import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import os

enum Permissions {
    /// Check if Screen Recording permission is granted.
    static func checkScreenRecording() -> Bool {
        PermissionHealthCheck.checkScreenRecordingLive() == .healthy
    }

    static func ensureMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
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
        guard !alreadyPrompted else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
