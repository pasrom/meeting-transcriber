#if !APPSTORE
    import AppKit
    @preconcurrency import ApplicationServices

    /// Request body for `POST /ui/type`: the accessibility `identifier` of the
    /// field to type into, the `text` to enter, and the `window` it lives in
    /// (defaults to `settings`).
    struct UITypePayload: Codable {
        let window: String?
        let identifier: String
        let text: String
        /// Replace the field's contents (select-all first) instead of typing at
        /// the cursor. Defaults to false — appending is what "type" means and is
        /// the non-destructive choice — but a driver asserting an exact value
        /// wants `true`, otherwise the result depends on the field's prior state.
        ///
        /// Known limitation: `clear` with an EMPTY `text` does not empty the
        /// field. Select-all only selects; the replacement happens because the
        /// following keystroke overwrites the selection, so with nothing typed the
        /// old text survives. Emptying a field would need a delete keystroke,
        /// which this endpoint does not send.
        let clear: Bool

        /// Hand-rolled so `clear` can be omitted by the caller yet stay a plain
        /// `Bool` here — an optional flag would push a `?? false` onto every use
        /// site and reads as a third state the endpoint does not have.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            window = try container.decodeIfPresent(String.self, forKey: .window)
            identifier = try container.decode(String.self, forKey: .identifier)
            text = try container.decode(String.self, forKey: .text)
            clear = try container.decodeIfPresent(Bool.self, forKey: .clear) ?? false
        }
    }

    /// The outcome of resolving a field and typing into it. `typed` carries
    /// whether focus + injection ran; the driver asserts on the *effect* via
    /// `/state`, not on this boolean.
    enum UITypeOutcome: Equatable {
        case typed(Bool)
        case notFound
        case disabled
    }

    /// Minimal actionable view of one accessibility element for text entry:
    /// enough to locate a field by `identifier`, decide whether it accepts input,
    /// and type into it. Separate from `UIPressTarget` because the concerns
    /// differ (focus + key events vs a press action) and a fake must be able to
    /// record the *text* it received.
    @MainActor
    protocol UITypeTarget {
        var uiIdentifier: String? { get }
        var uiEnabled: Bool { get }
        var uiChildren: [any UITypeTarget] { get }
        /// Focus the element and enter `text`, optionally replacing what is there.
        /// Returns whether it ran.
        func uiType(_ text: String, clear: Bool) -> Bool
    }

    /// `POST /ui/type` — enter text into an allowlisted field, so a driver can
    /// automate the one GUI acceptance that had no automated path: typing into a
    /// field, then asserting the resulting `AppSettings` write-back via
    /// `GET /state`.
    ///
    /// The field is located in the app's own self-pid `AXUIElement` tree (same
    /// plumbing and no-TCC rationale as `/ui/tree` and `/ui/press`), focused via
    /// `axFocus`, and filled by `KeyboardInjection` posting real key events. An
    /// accessibility set-value would be the obvious implementation and is the
    /// wrong one: it does not fire the SwiftUI binding, which is why no
    /// `/ui/setValue` exists.
    extension DebugRPCServer {
        /// Windows a type may target. Same allowlist rationale as `/ui/press`:
        /// only the Settings window. PII windows (`speaker-naming`, the
        /// live-captions panel) stay off.
        nonisolated static let uiTypeAllowedWindowIDs: Set<String> = ["settings"]

        /// Window used when the request omits `window`.
        nonisolated static let defaultUITypeWindow = "settings"

        /// Recursion cap — shares `/ui/tree`'s bound.
        nonisolated static let uiTypeMaxDepth = uiTreeMaxDepth

        nonisolated static func isWindowAllowedForUIType(identifier: String?) -> Bool {
            isWindowAllowed(identifier, in: uiTypeAllowedWindowIDs)
        }

        /// Fields a type may target, by accessibility identifier. Deliberately
        /// narrow, and narrower than `/ui/press`'s: text entry writes attacker-
        /// chosen content into a persisted setting, so without an allowlist a
        /// token-holder could rewrite any current-or-future field in the window
        /// (an endpoint URL, an output path).
        ///
        /// INVARIANT — never allowlist a secure field (`SecureField`, API keys,
        /// tokens). Posting into one is both a credential-handling hazard and
        /// unreliable (macOS Secure Event Input exists precisely to block
        /// synthetic input there). Plain, non-secret text fields only.
        nonisolated static let uiTypeAllowedIdentifiers: Set<String> = [A11yID.micNameField]

        /// Upper bound on a single request's text. Each character is posted as a
        /// key-event pair synchronously on the main actor and drives a settings
        /// write, so an unbounded string (the body cap alone allows ~64k) would
        /// freeze the UI and stall the server for the whole run.
        nonisolated static let uiTypeMaxTextLength = 512

        nonisolated static func isIdentifierAllowedForUIType(_ identifier: String) -> Bool {
            uiTypeAllowedIdentifiers.contains(identifier)
        }

        /// Depth-first search for the first element whose identifier matches, then
        /// act on it: `.disabled` (found but not accepting input, never typed
        /// into), `.typed` (found, enabled, filled), or `.notFound`. Identifiers
        /// are assumed unique per window, so first match wins. Pure over
        /// `UITypeTarget`, so it is unit-testable with a fake.
        static func performType(
            text: String, identifier: String, in root: any UITypeTarget, maxDepth: Int,
            clear: Bool = false,
        ) -> UITypeOutcome {
            if root.uiIdentifier == identifier {
                guard root.uiEnabled else { return .disabled }
                return .typed(root.uiType(text, clear: clear))
            }
            guard maxDepth > 0 else { return .notFound }
            for child in root.uiChildren {
                let outcome = performType(
                    text: text, identifier: identifier, in: child, maxDepth: maxDepth - 1,
                    clear: clear,
                )
                if outcome != .notFound {
                    return outcome
                }
            }
            return .notFound
        }

        /// Resolve the accessibility root *and* the `NSWindow` for an allowed,
        /// currently-open window, or nil when either is missing. Typing needs both:
        /// the AX element to focus the field, the window to post key events to.
        /// Both are absent in the headless xctest process, so both are guarded.
        static func uiTypeTarget(forWindowIdentifier identifier: String) -> (any UITypeTarget)? {
            guard let element = axWindowElement(forIdentifier: identifier),
                  let window = nsWindow(forIdentifier: identifier)
            else { return nil }
            return AXTypeSource(element: element, window: window)
        }

        /// Map a type outcome to its HTTP response. Pure so the 200/404/409 arms —
        /// unreachable through `route()` in the headless test harness, which has no
        /// live window to resolve — are unit-testable directly.
        ///
        /// Named rather than overloading `response(for:)`: `UIPressOutcome` and
        /// `UITypeOutcome` share case names, so an overload would make existing
        /// bare-case call sites (`response(for: .notFound)`) ambiguous.
        nonisolated static func uiTypeResponse(for outcome: UITypeOutcome) -> HTTPResponse {
            switch outcome {
            case .notFound:
                HTTPResponse.notFound()

            case .disabled:
                HTTPResponse.conflict()

            case let .typed(accepted):
                // `dispatched` for the same reason as `/ui/press`: it reports that
                // focus + injection ran, not that the binding took the text.
                HTTPResponse.ok(body: Data(#"{"dispatched":\#(accepted)}"#.utf8), contentType: "application/json")
            }
        }

        /// `POST /ui/type` handler. 400 undecodable body / empty identifier, 403
        /// window or identifier off its allowlist, 503 allowed window not open,
        /// 404 identifier absent, 409 present-but-disabled, 200 dispatched
        /// (`{"dispatched":<bool>}`).
        func uiTypeResponse(body: Data) -> HTTPResponse {
            guard let payload = try? JSONDecoder().decode(UITypePayload.self, from: body),
                  !payload.identifier.isEmpty,
                  payload.text.count <= Self.uiTypeMaxTextLength
            else { return HTTPResponse.badRequest() }
            let windowID = payload.window ?? Self.defaultUITypeWindow
            guard Self.isWindowAllowedForUIType(identifier: windowID),
                  Self.isIdentifierAllowedForUIType(payload.identifier)
            else { return HTTPResponse.forbidden() }
            guard let root = Self.uiTypeTarget(forWindowIdentifier: windowID) else {
                return HTTPResponse.serviceUnavailable("no window\n")
            }
            return Self.uiTypeResponse(for: Self.performType(
                text: payload.text, identifier: payload.identifier, in: root,
                maxDepth: Self.uiTypeMaxDepth, clear: payload.clear,
            ))
        }
    }

    /// Adapter bridging one self-pid `AXUIElement` (plus its hosting `NSWindow`)
    /// to `UITypeTarget` (mirrors `AXPressSource` in `+UIPress.swift`).
    @MainActor
    private struct AXTypeSource: UITypeTarget {
        let element: AXUIElement
        let window: NSWindow

        var uiIdentifier: String? {
            DebugRPCServer.axIdentifier(element)
        }

        var uiEnabled: Bool {
            DebugRPCServer.axEnabled(element)
        }

        var uiChildren: [any UITypeTarget] {
            DebugRPCServer.axChildren(element).map { Self(element: $0, window: window) }
        }

        func uiType(_ text: String, clear: Bool) -> Bool {
            guard DebugRPCServer.axFocus(element) else { return false }
            // Focusing a text field selects its contents, so the caret has to be
            // placed deliberately either way: keep the selection to replace it, or
            // collapse it to the end to append. Leaving it implicit makes the same
            // request replace or append depending on prior focus state. A refused
            // action is reported rather than silently doing the other thing.
            let positioned = clear
                ? KeyboardInjection.selectAll(in: window)
                : KeyboardInjection.moveToEnd(in: window)
            guard positioned else { return false }
            KeyboardInjection.type(text, into: window)
            return true
        }
    }
#endif
