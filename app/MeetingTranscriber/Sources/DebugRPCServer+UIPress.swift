#if !APPSTORE
    import AppKit
    import Foundation

    /// Request body for `POST /ui/press`: the accessibility `identifier` of the
    /// control to press, and the `window` it lives in (defaults to `settings`).
    struct UIPressPayload: Codable {
        let window: String?
        let identifier: String
    }

    /// The outcome of resolving and pressing a control inside a window's
    /// accessibility tree. `pressed` carries what `accessibilityPerformPress()`
    /// reported (the PoC unknown — see the extension header); the driver asserts
    /// on the *effect* via `/state`, not on this boolean.
    enum UIPressOutcome: Equatable {
        case pressed(Bool)
        case notFound
        case disabled
    }

    /// Minimal actionable view of one accessibility element: enough to locate a
    /// control by `identifier`, decide whether it accepts input, and press it.
    /// Separate from `UITreeNodeSource` (which is read-only and carries
    /// role/title/frame for serialization) because the press concern only needs
    /// identity + enabled + the press action, and its children must themselves be
    /// pressable. `@MainActor` because the production adapter reads AppKit
    /// accessibility state.
    @MainActor
    protocol UIPressTarget {
        var uiIdentifier: String? { get }
        var uiEnabled: Bool { get }
        var uiChildren: [any UIPressTarget] { get }
        /// Perform the accessibility press. Returns what the underlying
        /// `accessibilityPerformPress()` reports (whether the action ran).
        func uiPress() -> Bool
    }

    /// `POST /ui/press` — drive a real UI action (button/toggle press) against an
    /// allowlisted window, so a driver can flip a control and then assert the
    /// resulting state change via `GET /state` instead of only reading structure.
    ///
    /// Like `GET /ui/tree`, the press runs in-process against the app's own
    /// `NSAccessibility` hierarchy, which needs NO Accessibility TCC grant: TCC
    /// gates only cross-process AX (the `AXUIElement` C API `ParticipantReader`
    /// uses against other apps). `accessibilityPerformPress()` is a plain method
    /// call on our own element.
    ///
    /// PoC decision: this uses `accessibilityPerformPress()`, the in-process
    /// equivalent of what XCUITest does out-of-process. Whether it actually fires
    /// the SwiftUI action behind an AppKit-bridged control is the one unknown this
    /// slice answers — `scripts/test_rpc.sh` presses `recordOnlyToggle` and
    /// asserts `settings.recording.recordOnly` flips in `/state`. If a control ever
    /// reports `pressed:true` yet leaves `/state` unchanged, the documented
    /// fallback is synthesizing an in-process `NSEvent` mouse-down/up at the
    /// element's `accessibilityFrame` and routing it through `window.sendEvent`
    /// (also TCC-free); never `CGEvent` posting, which would need an Accessibility
    /// grant. The fallback is intentionally not built until the press path is
    /// proven insufficient.
    extension DebugRPCServer {
        /// Windows a press may target. Same allowlist rationale as `/ui/tree`:
        /// only the Settings window, which is already exposed via `/screenshot`.
        /// PII windows (`speaker-naming`, the live-captions panel) stay off.
        nonisolated static let uiPressAllowedWindowIDs: Set<String> = ["settings"]

        /// Window used when the request omits `window`.
        nonisolated static let defaultUIPressWindow = "settings"

        /// Recursion cap — shares `/ui/tree`'s bound; Settings is only a handful
        /// of levels deep so this never truncates the real tree.
        nonisolated static let uiPressMaxDepth = uiTreeMaxDepth

        nonisolated static func isWindowAllowedForUIPress(identifier: String?) -> Bool {
            isWindowAllowed(identifier, in: uiPressAllowedWindowIDs)
        }

        /// Controls a press may target, by accessibility identifier. Deliberately
        /// narrow: without it the endpoint could press *any* current-or-future
        /// control in an allowed window — including one whose action opens a modal
        /// panel (`NSOpenPanel.runModal()` etc.) that would block the main-actor
        /// RPC server, and any destructive control the UI later grows. Each entry
        /// is a reviewed, non-modal control; extend explicitly as a driver needs
        /// to drive more. Seeded with the record-only toggle (the PoC target).
        nonisolated static let uiPressAllowedIdentifiers: Set<String> = ["recordOnlyToggle"]

        nonisolated static func isIdentifierAllowedForUIPress(_ identifier: String) -> Bool {
            uiPressAllowedIdentifiers.contains(identifier)
        }

        /// Depth-first search for the first element whose identifier matches, then
        /// act on it: `.disabled` (found but not accepting input, never pressed),
        /// `.pressed` (found, enabled, pressed — carries the AX return value), or
        /// `.notFound`. Identifiers are assumed unique per window, so first match
        /// wins. Pure over `UIPressTarget`, so it is unit-testable with a fake.
        static func performPress(
            identifier: String, in root: any UIPressTarget, maxDepth: Int,
        ) -> UIPressOutcome {
            if root.uiIdentifier == identifier {
                guard root.uiEnabled else { return .disabled }
                return .pressed(root.uiPress())
            }
            guard maxDepth > 0 else { return .notFound }
            for child in root.uiChildren {
                let outcome = performPress(identifier: identifier, in: child, maxDepth: maxDepth - 1)
                if outcome != .notFound { return outcome }
            }
            return .notFound
        }

        /// Resolve the accessibility root for an allowed, currently-open window,
        /// or nil when no matching visible window exists. Shares `/ui/tree`'s
        /// window→contentView resolution; only the adapter differs.
        static func uiPressTarget(forWindowIdentifier identifier: String) -> (any UIPressTarget)? {
            visibleWindowContentView(identifier: identifier).map { AXPressTarget(element: $0) }
        }

        /// Map a press outcome to its HTTP response. Pure so the 200/404/409
        /// arms — unreachable through `route()` in the headless test harness,
        /// which has no live window to resolve — are unit-testable directly.
        nonisolated static func response(for outcome: UIPressOutcome) -> HTTPResponse {
            switch outcome {
            case .notFound:
                HTTPResponse.notFound()

            case .disabled:
                HTTPResponse.conflict()

            case let .pressed(accepted):
                HTTPResponse.ok(body: Data(#"{"pressed":\#(accepted)}"#.utf8), contentType: "application/json")
            }
        }

        /// `POST /ui/press` handler. 400 undecodable body / empty identifier, 403
        /// window or identifier off its allowlist, 503 allowed window not open,
        /// 404 identifier absent, 409 present-but-disabled, 200 pressed
        /// (`{"pressed":<bool>}`).
        func uiPressResponse(body: Data) -> HTTPResponse {
            guard let payload = try? JSONDecoder().decode(UIPressPayload.self, from: body),
                  !payload.identifier.isEmpty
            else { return HTTPResponse.badRequest() }
            let windowID = payload.window ?? Self.defaultUIPressWindow
            guard Self.isWindowAllowedForUIPress(identifier: windowID),
                  Self.isIdentifierAllowedForUIPress(payload.identifier)
            else { return HTTPResponse.forbidden() }
            guard let root = Self.uiPressTarget(forWindowIdentifier: windowID) else {
                return HTTPResponse.serviceUnavailable("no window\n")
            }
            return Self.response(for: Self.performPress(
                identifier: payload.identifier, in: root, maxDepth: Self.uiPressMaxDepth,
            ))
        }
    }

    /// Adapter bridging one AppKit accessibility element to `UIPressTarget`. Only
    /// children conforming to the umbrella `NSAccessibility` protocol are followed
    /// (mirrors `AXElementSource` in `+UITree.swift`).
    @MainActor
    private struct AXPressTarget: UIPressTarget {
        let element: any NSAccessibilityProtocol

        var uiIdentifier: String? {
            guard let identifier = element.accessibilityIdentifier(), !identifier.isEmpty else { return nil }
            return identifier
        }

        var uiEnabled: Bool {
            element.isAccessibilityEnabled()
        }

        var uiChildren: [any UIPressTarget] {
            (element.accessibilityChildren() ?? []).compactMap { child -> (any UIPressTarget)? in
                guard let ax = child as? any NSAccessibilityProtocol else { return nil }
                return Self(element: ax)
            }
        }

        func uiPress() -> Bool {
            element.accessibilityPerformPress()
        }
    }
#endif
