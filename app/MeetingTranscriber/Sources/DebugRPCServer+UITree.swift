#if !APPSTORE
    import AppKit
    import Foundation

    /// One node of the serialized accessibility tree — the Codable wire shape of
    /// `GET /ui/tree`. Structure and our developer-assigned identifiers only
    /// (role / identifier / frame / enabled) plus the recursive children.
    ///
    /// The endpoint's contract is deliberately "structure, not content": neither
    /// a control's `title`/`label` nor its `value` is exposed, because both can
    /// carry user-visible content (a mic name, an endpoint URL, a path) that the
    /// window allowlist alone doesn't scrub. Drivers assert on `identifier`
    /// (which the app sets, never user input) and `enabled`; add labels/values
    /// later behind field-level gating if a use case needs them.
    struct UITreeNode: Codable, Equatable {
        struct Frame: Codable, Equatable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        let role: String?
        let identifier: String?
        let frame: Frame
        let enabled: Bool
        let children: [Self]
    }

    /// Minimal read-only view of one accessibility element, abstracting AppKit's
    /// `NSAccessibility` so the recursive tree walk is unit-testable without a
    /// live window. `@MainActor` because the production adapter reads AppKit
    /// accessibility state, which is main-actor isolated.
    @MainActor
    protocol UITreeNodeSource {
        var uiRole: String? { get }
        var uiIdentifier: String? { get }
        var uiFrame: CGRect { get }
        var uiEnabled: Bool { get }
        var uiChildren: [any UITreeNodeSource] { get }
    }

    /// `GET /ui/tree` — read-only accessibility-tree inspection, line-cap split
    /// from DebugRPCServer.swift.
    ///
    /// The tree is walked in-process from the app's own `NSAccessibility`
    /// hierarchy, which needs NO Accessibility TCC grant: TCC only gates
    /// cross-process AX (the `AXUIElement` C API `ParticipantReader` uses against
    /// other apps). Reading our own tree is plain method calls.
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

        nonisolated static func isWindowAllowedForUITree(identifier: String?) -> Bool {
            isWindowAllowed(identifier, in: uiTreeAllowedWindowIDs)
        }

        /// The `window` query parameter off the raw request target, defaulting to
        /// `settings`.
        nonisolated static func uiTreeWindowParam(target: String) -> String {
            HTTPRequest.queryValues(target: target, key: "window").first ?? defaultUITreeWindow
        }

        /// Recursively convert an accessibility source into the Codable wire
        /// shape, capping recursion at `maxDepth` levels of descendants.
        static func buildUITree(from source: any UITreeNodeSource, maxDepth: Int) -> UITreeNode {
            let children: [UITreeNode] = maxDepth <= 0
                ? []
                : source.uiChildren.map { buildUITree(from: $0, maxDepth: maxDepth - 1) }
            let frame = source.uiFrame
            return UITreeNode(
                role: source.uiRole,
                identifier: source.uiIdentifier,
                frame: .init(
                    x: Double(frame.origin.x), y: Double(frame.origin.y),
                    width: Double(frame.size.width), height: Double(frame.size.height),
                ),
                enabled: source.uiEnabled,
                children: children,
            )
        }

        /// Resolve the accessibility root for an allowed, currently-open window,
        /// or nil when no matching visible window exists. Walks
        /// `NSApplication.shared.windows` the same way `/screenshot` does. Starts
        /// from the window's `contentView` (an `NSView`, always a conforming
        /// accessibility element) rather than the `NSWindow` itself.
        static func uiTreeSource(forWindowIdentifier identifier: String) -> (any UITreeNodeSource)? {
            let window = NSApplication.shared.windows.first { window in
                window.identifier?.rawValue == identifier && window.isVisible
            }
            guard let root = window?.contentView else { return nil }
            return AXElementSource(element: root)
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

    /// Adapter bridging one AppKit accessibility element to `UITreeNodeSource`.
    /// Only children conforming to the umbrella `NSAccessibility` protocol are
    /// followed; an element exposing just the base element protocol is dropped
    /// (it carries no `accessibilityChildren` anyway). Reads only structural
    /// attributes — no title/label or value (see `UITreeNode`).
    @MainActor
    private struct AXElementSource: UITreeNodeSource {
        let element: any NSAccessibilityProtocol

        var uiRole: String? {
            element.accessibilityRole()?.rawValue
        }

        var uiIdentifier: String? {
            guard let identifier = element.accessibilityIdentifier(), !identifier.isEmpty else { return nil }
            return identifier
        }

        var uiFrame: CGRect {
            element.accessibilityFrame()
        }

        var uiEnabled: Bool {
            element.isAccessibilityEnabled()
        }

        var uiChildren: [any UITreeNodeSource] {
            (element.accessibilityChildren() ?? []).compactMap { child -> (any UITreeNodeSource)? in
                guard let ax = child as? any NSAccessibilityProtocol else { return nil }
                return Self(element: ax)
            }
        }
    }
#endif
