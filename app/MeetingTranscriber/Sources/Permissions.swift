// `@preconcurrency`: `kAXTrustedCheckOptionPrompt` is a C `var` global
// (process-load-immutable in practice); SDK lacks Sendable annotations.
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Permissions")

enum Permissions {
    /// Bridge the C global `kAXTrustedCheckOptionPrompt` once at type init.
    /// `String` is `Sendable`, and the import is `@preconcurrency` so the
    /// var-classified C global doesn't escape into the rest of the file.
    static let axPromptKey: String =
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

    /// Check if Screen Recording permission is granted.
    static func checkScreenRecording() -> Bool {
        let granted = PermissionHealthCheck.checkScreenRecordingLive() == .healthy
        if !granted {
            logger.warning("permission_denied resource=screen_recording — required for meeting detection")
        }
        return granted
    }

    /// Take a one-shot flag: true when this caller is the first to claim it.
    /// Shared by the prompt guards below, which would otherwise each hand-roll
    /// the same test-and-set in a slightly different shape.
    private static func claimFirst(_ lock: OSAllocatedUnfairLock<Bool>) -> Bool {
        lock.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }

    private static let screenRecordingPromptLock = OSAllocatedUnfairLock(initialState: false)

    /// Ask macOS for Screen Recording, at most once per session.
    ///
    /// `CGRequestScreenCaptureAccess` is the only call that registers the app in
    /// the Screen Recording list; `CGPreflightScreenCaptureAccess` reports
    /// status and registers nothing. Until the app is in that list there is
    /// nothing for the user to switch on, and the "Open System Settings" link
    /// opens a pane the app is absent from.
    ///
    /// Unlike the microphone, this cannot grant in place: macOS offers only
    /// Deny or Open System Settings, the toggle stays there, and the grant takes
    /// effect on the next launch. So the win is turning "find the bundle inside
    /// a hidden folder" into "flip the switch that is already there".
    ///
    /// The already-granted check comes first so a session that starts granted
    /// does not burn the one-shot flag: if the grant is revoked mid-session, the
    /// next watch start still asks.
    static func ensureScreenRecordingAccess() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        guard claimFirst(screenRecordingPromptLock) else { return }

        if !CGRequestScreenCaptureAccess() {
            logger.warning("permission_denied resource=screen_recording status=user_denied_prompt")
        }
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
        // `kAXTrustedCheckOptionPrompt` is a C global imported as
        // `Unmanaged<CFString>!`, which Swift 6 treats as shared mutable
        // state. The value is set by AppKit at process load and never
        // mutates; bridge once via a nonisolated(unsafe) wrapper.
        let options = [Self.axPromptKey: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        if !granted {
            logger.warning("permission_denied resource=accessibility status=user_denied_prompt")
        }
        return granted
    }
}
