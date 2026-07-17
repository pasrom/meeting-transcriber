#if !APPSTORE
    @preconcurrency import ApplicationServices
    import Foundation

    /// One node of the serialized accessibility tree — the Codable wire shape of
    /// `GET /ui/tree`: role / identifier / title / frame / enabled plus the
    /// recursive children.
    ///
    /// `title` is the control's label — a static string for most controls
    /// ("Record Only", "Microphone Name"). It is home-directory redacted so a
    /// displayed path can't leak the account name; the Settings window is the
    /// only allowlisted window and its content is already exposed via
    /// `/screenshot`, so labels here don't widen the surface. That parity holds
    /// only because presented sheets are pruned from the walk (see
    /// `uiTreeSheetRole`) — a sheet is a separate window `/screenshot` doesn't
    /// capture and can carry PII (speaker names). A control's `value` (a text
    /// field's typed contents — mic name, endpoint URL) is likewise deliberately
    /// NOT exposed: that is user-entered content, and drivers assert on
    /// `identifier` (app-set, never user input) and `enabled` anyway.
    struct UITreeNode: Codable, Equatable {
        struct Frame: Codable, Equatable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        let role: String?
        let identifier: String?
        let title: String?
        let frame: Frame
        let enabled: Bool
        let children: [Self]
    }

    /// Minimal read-only view of one accessibility element, abstracting the
    /// underlying `AXUIElement` so the recursive tree walk is unit-testable
    /// without a live window. `@MainActor` because the production adapter reads
    /// self-pid AX state, which must run on the main actor.
    @MainActor
    protocol UITreeNodeSource {
        var uiRole: String? { get }
        var uiIdentifier: String? { get }
        var uiTitle: String? { get }
        var uiFrame: CGRect { get }
        var uiEnabled: Bool { get }
        var uiChildren: [any UITreeNodeSource] { get }
    }

    /// `GET /ui/tree` — read-only accessibility-tree inspection, line-cap split
    /// from DebugRPCServer.swift.
    ///
    /// The tree is walked in-process from the app's own `AXUIElement` hierarchy
    /// (see the `DebugRPCServer.ax*` helpers in `DebugRPCServer+AXElement.swift`),
    /// which surfaces SwiftUI's real identifiers/labels and needs NO Accessibility
    /// TCC grant (self-inspection is exempt). The older
    /// `NSView.accessibilityChildren()` walk returned an empty SwiftUI tree.
    extension DebugRPCServer {
        /// SwiftUI scene identifiers exposed to `GET /ui/tree`. Deliberately only
        /// the Settings window for now — `speaker-naming`, `record-app`, and the
        /// live-captions panel stay off the list because they surface PII /
        /// meeting content. Same rationale that keeps SpeakerNamingView off
        /// `/screenshot`.
        nonisolated static let uiTreeAllowedWindowIDs: Set<String> = ["settings"]

        /// Window used when the `?window=` query parameter is omitted.
        nonisolated static let defaultUITreeWindow = "settings"

        /// Recursion cap so a pathological hierarchy can't recurse without bound
        /// or return a multi-megabyte body. Settings is only a handful of levels
        /// deep, so this never truncates the real tree.
        nonisolated static let uiTreeMaxDepth = 40

        /// AX role of a presented sheet. A SwiftUI `.sheet` over the allowlisted
        /// window (e.g. Known Voices, which renders saved speaker names) is
        /// realized as an `AXSheet` *descendant* of that window, yet it is a
        /// separate `NSWindow` that `/screenshot` does NOT capture. Excluding the
        /// sheet subtree keeps `/ui/tree` bounded by what `/screenshot` shows, so
        /// no name/PII inside a sheet leaks here (confirmed live: an open sheet
        /// otherwise adds a ~600-node subtree with the speaker-name labels).
        nonisolated static let uiTreeSheetRole = "AXSheet"

        nonisolated static func isWindowAllowedForUITree(identifier: String?) -> Bool {
            isWindowAllowed(identifier, in: uiTreeAllowedWindowIDs)
        }

        /// The `window` query parameter off the raw request target, defaulting to
        /// `settings`.
        nonisolated static func uiTreeWindowParam(target: String) -> String {
            HTTPRequest.queryValues(target: target, key: "window").first ?? defaultUITreeWindow
        }

        /// Replace a home-directory prefix in a title/label with `~` so a
        /// displayed folder or URL can't leak the account name. Anchored on the
        /// path separator (`home + "/"`) so a longer sibling like
        /// `/Users/romantic` is never mangled; a bare home path collapses to `~`.
        /// Pure so it is unit-testable; the adapter passes `NSHomeDirectory()`.
        nonisolated static func redactUITreeString(_ value: String?, homeDirectory: String) -> String? {
            guard let value, !homeDirectory.isEmpty else { return value }
            let abbreviated = value.replacingOccurrences(of: homeDirectory + "/", with: "~/")
            return abbreviated == homeDirectory ? "~" : abbreviated
        }

        /// Recursively convert an accessibility source into the Codable wire
        /// shape, capping recursion at `maxDepth` levels of descendants. Presented
        /// sheets (`uiTreeSheetRole`) are pruned — their content is off-screen PII
        /// that `/screenshot` doesn't capture (see `uiTreeSheetRole`).
        static func buildUITree(from source: any UITreeNodeSource, maxDepth: Int) -> UITreeNode {
            let children: [UITreeNode] = maxDepth <= 0
                ? []
                : source.uiChildren
                .filter { $0.uiRole != uiTreeSheetRole }
                .map { buildUITree(from: $0, maxDepth: maxDepth - 1) }
            let frame = source.uiFrame
            return UITreeNode(
                role: source.uiRole,
                identifier: source.uiIdentifier,
                title: source.uiTitle,
                frame: .init(
                    x: Double(frame.origin.x), y: Double(frame.origin.y),
                    width: Double(frame.size.width), height: Double(frame.size.height),
                ),
                enabled: source.uiEnabled,
                children: children,
            )
        }

        /// Resolve the accessibility root for an allowed, currently-open window,
        /// or nil when no matching open window exists. Finds the window by its
        /// `AXIdentifier` in the app-wide self-pid AX tree (shared with
        /// `/ui/press`), so the walk is scoped to that window's subtree.
        static func uiTreeSource(forWindowIdentifier identifier: String) -> (any UITreeNodeSource)? {
            axWindowElement(forIdentifier: identifier).map { AXTreeSource(element: $0) }
        }

        /// `GET /ui/tree?window=<id>` handler. 403 when the window isn't on the
        /// allowlist, 503 when it is but isn't currently open, 200 with the JSON
        /// tree otherwise.
        func uiTreeResponse(target: String) -> HTTPResponse {
            let windowID = Self.uiTreeWindowParam(target: target)
            guard Self.isWindowAllowedForUITree(identifier: windowID) else {
                return HTTPResponse.forbidden()
            }
            guard let source = Self.uiTreeSource(forWindowIdentifier: windowID) else {
                return HTTPResponse.serviceUnavailable("no window\n")
            }
            let tree = Self.buildUITree(from: source, maxDepth: Self.uiTreeMaxDepth)
            guard let body = try? JSONEncoder().encode(tree) else { return HTTPResponse.internalServerError() }
            return HTTPResponse.ok(body: body, contentType: "application/json")
        }
    }

    /// Adapter bridging one self-pid `AXUIElement` to `UITreeNodeSource` via the
    /// shared `DebugRPCServer.ax*` plumbing. Reads role / identifier / title /
    /// frame / enabled; the title is home-directory redacted and the control's
    /// `value` is deliberately not read (see `UITreeNode`).
    @MainActor
    private struct AXTreeSource: UITreeNodeSource {
        let element: AXUIElement

        var uiRole: String? {
            DebugRPCServer.axRole(element)
        }

        var uiIdentifier: String? {
            DebugRPCServer.axIdentifier(element)
        }

        var uiTitle: String? {
            DebugRPCServer.redactUITreeString(DebugRPCServer.axLabel(element), homeDirectory: NSHomeDirectory())
        }

        var uiFrame: CGRect {
            DebugRPCServer.axFrame(element)
        }

        var uiEnabled: Bool {
            DebugRPCServer.axEnabled(element)
        }

        var uiChildren: [any UITreeNodeSource] {
            DebugRPCServer.axChildren(element).map { Self(element: $0) }
        }
    }
#endif
