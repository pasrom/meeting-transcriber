import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

enum Permissions {
    /// Check if Screen Recording permission is granted.
    static func checkScreenRecording() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windowList.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID else { return false }
            return info[kCGWindowName as String] is String
        }
    }

    static func ensureMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        return false
    }

    private static var hasPromptedAccessibility = false
    // swiftlint:disable:next unused_declaration
    static func ensureAccessibilityAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard !hasPromptedAccessibility else { return false }
        hasPromptedAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
