// `@preconcurrency import ScreenCaptureKit`: SCShareableContent isn't
// Sendable on macos-26 SDK; call sites are @MainActor so it's safe.
#if !APPSTORE
    import AppKit
    import Foundation
    import os.log
    @preconcurrency import ScreenCaptureKit

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DebugRPCServer")

    /// `GET /screenshot` — PNG capture of the largest allowlisted window, line-cap
    /// split from DebugRPCServer.swift.
    extension DebugRPCServer {
        /// Skip status-item-style windows. The menu-bar `keyWindow` at idle is a
        /// 68×66 invisible rect — capturing it returns useless white pixels.
        private static let minWindowAreaPx: CGFloat = 10000

        /// SwiftUI scene identifiers we expose to `/screenshot`. SpeakerNamingView
        /// (`speaker-naming`) is deliberately excluded because it surfaces real
        /// participant names and meeting titles — capturing it would let any
        /// local process with the RPC token read PII off-screen. Record-app
        /// picker (`record-app`) is excluded by default for the same reason
        /// (it lists the user's running apps); add to the set if a screenshot
        /// of it becomes useful for debugging. System file pickers, AppKit
        /// alerts, and similar transients carry no SwiftUI identifier and are
        /// rejected by the nil/empty case.
        nonisolated static let screenshotAllowedWindowIDs: Set<String> = ["settings"]

        nonisolated static func isWindowAllowedForScreenshot(identifier: String?) -> Bool {
            isWindowAllowed(identifier, in: screenshotAllowedWindowIDs)
        }

        /// Non-empty window identifier that appears in `allowed`. Shared by the
        /// `/screenshot` and `/ui/tree` allowlist checks so they can't drift.
        nonisolated static func isWindowAllowed(_ identifier: String?, in allowed: Set<String>) -> Bool {
            guard let identifier, !identifier.isEmpty else { return false }
            return allowed.contains(identifier)
        }

        /// The content view of a currently-visible window with the given
        /// identifier, or nil when no such window is open. Shared window→view
        /// resolution for the in-process accessibility endpoints (`/ui/tree`,
        /// `/ui/press`) so they can't drift; each wraps the returned view in its
        /// own adapter. Walks `NSApplication.shared.windows` the same way
        /// `/screenshot` selects a window.
        static func visibleWindowContentView(identifier: String) -> NSView? {
            NSApplication.shared.windows.first { window in
                window.identifier?.rawValue == identifier && window.isVisible
            }?.contentView
        }

        /// PNG of the largest visible content window from the screenshot
        /// allowlist, or nil when none qualifies. Uses ScreenCaptureKit
        /// (`SCScreenshotManager.captureImage`) — the non-deprecated successor
        /// to `CGWindowListCreateImage`. Unlike the old API, SCK requires
        /// Screen Recording permission even for self-capture; the first
        /// request triggers the standard TCC prompt. Acceptable for this
        /// debug-only path (whole file is `#if !APPSTORE`, RPC is opt-in).
        @MainActor
        static func captureFrontmostWindowPNG() async -> Data? {
            let app = NSApplication.shared
            let area: (NSWindow) -> CGFloat = { window in
                let b = window.contentView?.bounds ?? .zero
                return b.width * b.height
            }
            let candidate = app.windows
                .filter { window in
                    isWindowAllowedForScreenshot(identifier: window.identifier?.rawValue)
                        && window.isVisible
                        && window.contentView != nil
                }
                .max { area($0) < area($1) }
            guard let window = candidate, area(window) >= minWindowAreaPx else { return nil }
            let windowID = CGWindowID(window.windowNumber)
            do {
                let content = try await SCShareableContent.current
                guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                    return nil
                }
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                let scale = window.backingScaleFactor
                config.width = max(Int(scWindow.frame.width * scale), 1)
                config.height = max(Int(scWindow.frame.height * scale), 1)
                config.showsCursor = false
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config,
                )
                let rep = NSBitmapImageRep(cgImage: cgImage)
                return rep.representation(using: .png, properties: [:])
            } catch {
                logger.warning("Screenshot capture failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
#endif
