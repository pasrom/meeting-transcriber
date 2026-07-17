#if !APPSTORE
    @preconcurrency import ApplicationServices
    import Foundation

    /// Request body for `POST /ui/press`: the accessibility `identifier` of the
    /// control to press, and the `window` it lives in (defaults to `settings`).
    struct UIPressPayload: Codable {
        let window: String?
        let identifier: String
    }

    /// The outcome of resolving and pressing a control inside a window's
    /// accessibility tree. `pressed` carries whether the AX press action reported
    /// it ran; the driver asserts on the *effect* via `/state`, not on this
    /// boolean.
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
    /// pressable. `@MainActor` because the production adapter reads self-pid AX
    /// state and fires the press, both of which must run on the main actor.
    @MainActor
    protocol UIPressTarget {
        var uiIdentifier: String? { get }
        var uiEnabled: Bool { get }
        var uiChildren: [any UIPressTarget] { get }
        /// Fire the element's AX press action. Returns whether it reported running.
        func uiPress() -> Bool
    }

    /// `POST /ui/press` — drive a real UI action (button/toggle press) against an
    /// allowlisted window, so a driver can flip a control and then assert the
    /// resulting state change via `GET /state` instead of only reading structure.
    ///
    /// Like `GET /ui/tree`, the press runs against the app's own self-pid
    /// `AXUIElement` tree via the shared `DebugRPCServer.ax*` helpers (see
    /// `DebugRPCServer+AXElement.swift` for the no-TCC / main-actor / why-not-NSView
    /// rationale). The control is located by `AXIdentifier` and fired with
    /// `AXUIElementPerformAction(kAXPressAction)`.
    ///
    /// Validated end-to-end: pressing `recordOnlyToggle` flips
    /// `settings.recording.recordOnly` in `/state` (`scripts/test_rpc.sh` asserts
    /// the effect, not the returned flag).
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
        /// control in an allowed window, including any destructive control the UI
        /// later grows. Seeded with the record-only toggle (the PoC target); extend
        /// explicitly per control as a driver needs to drive more.
        ///
        /// INVARIANT — never allowlist a control whose action can enter a nested
        /// runloop or modal session (menu tracking, popover, sheet, `NSAlert`,
        /// `NSOpenPanel.runModal()`): `kAXPressAction` runs synchronously in the
        /// RPC handler on the main actor, so such a press would never return and
        /// would wedge the server and UI. This invariant, not the (localhost +
        /// token + env-gated + `#if !APPSTORE`) security margin, is the allowlist's
        /// real justification.
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
        /// or nil when no matching open window exists. Shares `/ui/tree`'s self-pid
        /// window resolution; only the adapter differs.
        static func uiPressTarget(forWindowIdentifier identifier: String) -> (any UIPressTarget)? {
            axWindowElement(forIdentifier: identifier).map { AXPressSource(element: $0) }
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

    /// Adapter bridging one self-pid `AXUIElement` to `UIPressTarget` via the
    /// shared `DebugRPCServer.ax*` plumbing (mirrors `AXTreeSource` in
    /// `+UITree.swift`).
    @MainActor
    private struct AXPressSource: UIPressTarget {
        let element: AXUIElement

        var uiIdentifier: String? {
            DebugRPCServer.axIdentifier(element)
        }

        var uiEnabled: Bool {
            DebugRPCServer.axEnabled(element)
        }

        var uiChildren: [any UIPressTarget] {
            DebugRPCServer.axChildren(element).map { Self(element: $0) }
        }

        func uiPress() -> Bool {
            DebugRPCServer.axPress(element)
        }
    }
#endif
