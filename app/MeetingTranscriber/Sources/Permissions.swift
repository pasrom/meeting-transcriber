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
            return info[kCGWindowName as String] as? String != nil
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
    static func ensureAccessibilityAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard !hasPromptedAccessibility else { return false }
        hasPromptedAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Walk up from executable to find the project root (directory containing VERSION).
    static func findProjectRoot(from startURL: URL? = nil) -> String? {
        let start = startURL ?? URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        var dir = start.deletingLastPathComponent()

        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("VERSION")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
