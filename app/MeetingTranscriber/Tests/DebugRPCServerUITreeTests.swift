#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Unit tests for the read-only `GET /ui/tree` accessibility-tree endpoint.
    /// The pure builder / param-parser / allowlist / redaction are exercised with
    /// an in-memory source; the AppKit walk (the 200 path) is validated live by
    /// `scripts/test_rpc.sh`, mirroring how `/screenshot` is tested.
    final class DebugRPCServerUITreeTests: XCTestCase {
        private static let testToken = "testtoken1234"

        /// In-memory `UITreeNodeSource` so the tree builder runs without a live
        /// AppKit window. `@MainActor` mirrors the protocol's isolation.
        @MainActor
        private final class FakeSource: UITreeNodeSource {
            var uiRole: String?
            var uiIdentifier: String?
            var uiTitle: String?
            var uiFrame: CGRect
            var uiEnabled: Bool
            var uiChildren: [any UITreeNodeSource]

            init(
                role: String? = nil, identifier: String? = nil, title: String? = nil,
                frame: CGRect = .zero, enabled: Bool = true,
                children: [any UITreeNodeSource] = [],
            ) {
                uiRole = role
                uiIdentifier = identifier
                uiTitle = title
                uiFrame = frame
                uiEnabled = enabled
                uiChildren = children
            }
        }

        // MARK: - buildUITree

        @MainActor
        func testBuildUITreeMapsFieldsAndChildren() {
            let child = FakeSource(
                role: "AXCheckBox", identifier: "recordOnlyToggle", title: "Record Only",
                frame: CGRect(x: 10, y: 20, width: 30, height: 40), enabled: false,
            )
            let root = FakeSource(
                role: "AXWindow", identifier: nil, title: "Settings",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                enabled: true, children: [child],
            )

            let tree = DebugRPCServer.buildUITree(from: root, maxDepth: 10)

            XCTAssertEqual(tree.role, "AXWindow")
            XCTAssertNil(tree.identifier)
            XCTAssertEqual(tree.title, "Settings")
            XCTAssertEqual(tree.frame.width, 800)
            XCTAssertTrue(tree.enabled)
            XCTAssertEqual(tree.children.count, 1)

            let mapped = tree.children[0]
            XCTAssertEqual(mapped.role, "AXCheckBox")
            XCTAssertEqual(mapped.identifier, "recordOnlyToggle")
            XCTAssertEqual(mapped.title, "Record Only")
            XCTAssertEqual(mapped.frame.x, 10)
            XCTAssertEqual(mapped.frame.height, 40)
            XCTAssertFalse(mapped.enabled)
        }

        @MainActor
        func testBuildUITreeRespectsMaxDepth() {
            let leaf = FakeSource(identifier: "leaf")
            let mid = FakeSource(identifier: "mid", children: [leaf])
            let root = FakeSource(identifier: "root", children: [mid])

            let depth0 = DebugRPCServer.buildUITree(from: root, maxDepth: 0)
            XCTAssertTrue(depth0.children.isEmpty, "maxDepth 0 must drop all descendants")

            let depth1 = DebugRPCServer.buildUITree(from: root, maxDepth: 1)
            XCTAssertEqual(depth1.children.count, 1)
            XCTAssertTrue(depth1.children[0].children.isEmpty, "maxDepth 1 truncates below the first level")

            let depth2 = DebugRPCServer.buildUITree(from: root, maxDepth: 2)
            XCTAssertEqual(depth2.children.first?.children.first?.identifier, "leaf")
        }

        @MainActor
        func testBuildUITreePrunesSheetSubtrees() {
            // A sheet presented over the window (AXSheet) carries off-screen PII
            // (e.g. saved speaker names) that /screenshot doesn't capture — its
            // whole subtree must be excluded from the tree.
            let nameLabel = FakeSource(role: "AXStaticText", title: "Some Speaker Name")
            let sheet = FakeSource(role: "AXSheet", title: "Known Voices", children: [nameLabel])
            let baseControl = FakeSource(role: "AXCheckBox", identifier: "recordOnlyToggle", title: "Record Only")
            let root = FakeSource(role: "AXWindow", title: "Settings", children: [baseControl, sheet])

            let tree = DebugRPCServer.buildUITree(from: root, maxDepth: 10)

            XCTAssertEqual(tree.children.count, 1, "the AXSheet child must be pruned, the base control kept")
            XCTAssertEqual(tree.children.first?.identifier, "recordOnlyToggle")

            func containsSheetOrName(_ node: UITreeNode) -> Bool {
                if node.role == "AXSheet" || node.title == "Some Speaker Name" { return true }
                return node.children.contains(where: containsSheetOrName)
            }
            XCTAssertFalse(containsSheetOrName(tree), "no AXSheet node or its name label may surface")
        }

        @MainActor
        func testUITreeNodeJSONRoundTrips() throws {
            let root = FakeSource(
                role: "AXWindow", identifier: "settings",
                frame: CGRect(x: 1, y: 2, width: 3, height: 4),
                children: [FakeSource(identifier: "recordOnlyToggle")],
            )
            let tree = DebugRPCServer.buildUITree(from: root, maxDepth: 5)

            let data = try JSONEncoder().encode(tree)
            let json = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(json.contains("\"identifier\":\"recordOnlyToggle\""))
            XCTAssertTrue(json.contains("\"frame\""))

            let decoded = try JSONDecoder().decode(UITreeNode.self, from: data)
            XCTAssertEqual(decoded, tree)
        }

        // MARK: - window param (pure)

        func testUITreeWindowParamParsing() {
            XCTAssertEqual(DebugRPCServer.uiTreeWindowParam(target: "/ui/tree"), "settings")
            XCTAssertEqual(DebugRPCServer.uiTreeWindowParam(target: "/ui/tree?window=general"), "general")
            XCTAssertEqual(DebugRPCServer.uiTreeWindowParam(target: "/ui/tree?foo=bar"), "settings")
            XCTAssertEqual(DebugRPCServer.uiTreeWindowParam(target: "/ui/tree?window=settings&x=1"), "settings")
            XCTAssertEqual(DebugRPCServer.uiTreeWindowParam(target: "/ui/tree?x=1&window=live-captions"), "live-captions")
        }

        // MARK: - allowlist (pure)

        func testIsWindowAllowedForUITree() {
            XCTAssertTrue(DebugRPCServer.isWindowAllowedForUITree(identifier: "settings"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUITree(identifier: "speaker-naming"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUITree(identifier: "record-app"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUITree(identifier: "live-captions"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUITree(identifier: ""))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUITree(identifier: nil))
        }

        // MARK: - redaction (pure)

        func testRedactUITreeStringAbbreviatesHomeAtPathBoundary() {
            XCTAssertEqual(
                DebugRPCServer.redactUITreeString("/Users/roman/Documents/out.md", homeDirectory: "/Users/roman"),
                "~/Documents/out.md",
            )
            // A displayed path mid-string is abbreviated too.
            XCTAssertEqual(
                DebugRPCServer.redactUITreeString("Saving to /Users/roman/x", homeDirectory: "/Users/roman"),
                "Saving to ~/x",
            )
            // The bare home path collapses to "~".
            XCTAssertEqual(DebugRPCServer.redactUITreeString("/Users/roman", homeDirectory: "/Users/roman"), "~")
            // A longer sibling must NOT be mangled (path-boundary guard).
            XCTAssertEqual(
                DebugRPCServer.redactUITreeString("/Users/romantic/file", homeDirectory: "/Users/roman"),
                "/Users/romantic/file",
            )
            XCTAssertNil(DebugRPCServer.redactUITreeString(nil, homeDirectory: "/Users/roman"))
            XCTAssertEqual(
                DebugRPCServer.redactUITreeString("/Users/roman/x", homeDirectory: ""),
                "/Users/roman/x",
                "an empty home directory must leave the string untouched",
            )
        }

        // MARK: - route

        private func authed(_ method: String, _ path: String) -> HTTPRequest {
            HTTPRequest(method: method, path: path, headers: ["authorization": "Bearer \(Self.testToken)"])
        }

        @MainActor
        func testRouteUITreeDisallowedWindowReturns403() async {
            // The allowlist check precedes window resolution, so a PII window is
            // refused even when it isn't open.
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(authed("GET", "/ui/tree?window=speaker-naming"))
            XCTAssertEqual(response.status, 403)
        }

        @MainActor
        func testRouteUITreeAllowedButNoWindowReturns503() async {
            // Tests run headless — NSApp has no "settings" window, so resolution
            // returns nil and the route maps to 503 (mirrors /screenshot).
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(authed("GET", "/ui/tree?window=settings"))
            XCTAssertEqual(response.status, 503)
        }

        @MainActor
        func testRouteUITreeRequiresAuth() async {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(HTTPRequest(method: "GET", path: "/ui/tree?window=settings"))
            XCTAssertEqual(response.status, 401)
        }
    }
#endif
