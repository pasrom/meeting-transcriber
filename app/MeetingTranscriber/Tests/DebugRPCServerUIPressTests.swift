#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Unit tests for the `POST /ui/press` accessibility-press endpoint. The pure
    /// depth-first search / press dispatch / payload decode / allowlist are
    /// exercised with an in-memory target; the AppKit press (the 200 path, and the
    /// PoC question of whether an in-process `accessibilityPerformPress()` fires the
    /// SwiftUI action) is validated live by `scripts/test_rpc.sh`, mirroring how
    /// `/screenshot` and `/ui/tree` are tested.
    final class DebugRPCServerUIPressTests: XCTestCase {
        private static let testToken = "testtoken1234"

        /// In-memory `UIPressTarget` recording whether `uiPress()` was invoked, so
        /// a test can prove the disabled path never presses.
        @MainActor
        private final class FakePressTarget: UIPressTarget {
            var uiIdentifier: String?
            var uiEnabled: Bool
            var uiChildren: [any UIPressTarget]
            let pressReturns: Bool
            private(set) var pressCallCount = 0

            init(
                identifier: String? = nil, enabled: Bool = true,
                pressReturns: Bool = true, children: [any UIPressTarget] = [],
            ) {
                uiIdentifier = identifier
                uiEnabled = enabled
                self.pressReturns = pressReturns
                uiChildren = children
            }

            func uiPress() -> Bool {
                pressCallCount += 1
                return pressReturns
            }
        }

        // MARK: - performPress (pure search + dispatch)

        @MainActor
        func testPerformPressFiresOnEnabledMatch() {
            let target = FakePressTarget(identifier: "recordOnlyToggle")
            let root = FakePressTarget(identifier: "settings", children: [target])

            let outcome = DebugRPCServer.performPress(identifier: "recordOnlyToggle", in: root, maxDepth: 10)

            XCTAssertEqual(outcome, .pressed(true))
            XCTAssertEqual(target.pressCallCount, 1, "the matched enabled element must be pressed exactly once")
            XCTAssertEqual(root.pressCallCount, 0, "a non-matching ancestor must never be pressed")
        }

        @MainActor
        func testPerformPressDisabledMatchReturnsDisabledWithoutPressing() {
            let target = FakePressTarget(identifier: "recordOnlyToggle", enabled: false)
            let root = FakePressTarget(identifier: "settings", children: [target])

            let outcome = DebugRPCServer.performPress(identifier: "recordOnlyToggle", in: root, maxDepth: 10)

            XCTAssertEqual(outcome, .disabled)
            XCTAssertEqual(target.pressCallCount, 0, "a disabled element must not be pressed")
        }

        @MainActor
        func testPerformPressUnknownIdentifierReturnsNotFound() {
            let child = FakePressTarget(identifier: "somethingElse")
            let root = FakePressTarget(identifier: "settings", children: [child])

            let outcome = DebugRPCServer.performPress(identifier: "recordOnlyToggle", in: root, maxDepth: 10)

            XCTAssertEqual(outcome, .notFound)
            XCTAssertEqual(child.pressCallCount, 0)
        }

        @MainActor
        func testPerformPressReportsPressReturnValue() {
            // The PoC unknown surfaces here: an element that accepts the AX press
            // reports true; one that declines reports false. The HTTP body carries
            // this through so the driver can distinguish it from the /state effect.
            let target = FakePressTarget(identifier: "recordOnlyToggle", pressReturns: false)
            let root = FakePressTarget(identifier: "settings", children: [target])

            let outcome = DebugRPCServer.performPress(identifier: "recordOnlyToggle", in: root, maxDepth: 10)

            XCTAssertEqual(outcome, .pressed(false))
            XCTAssertEqual(target.pressCallCount, 1)
        }

        @MainActor
        func testPerformPressFindsDeeplyNestedTarget() {
            let target = FakePressTarget(identifier: "recordOnlyToggle")
            let mid = FakePressTarget(identifier: "section", children: [target])
            let root = FakePressTarget(identifier: "settings", children: [mid])

            let outcome = DebugRPCServer.performPress(identifier: "recordOnlyToggle", in: root, maxDepth: 10)

            XCTAssertEqual(outcome, .pressed(true))
            XCTAssertEqual(target.pressCallCount, 1)
        }

        @MainActor
        func testPerformPressMatchesRootRegardlessOfDepth() {
            let root = FakePressTarget(identifier: "recordOnlyToggle")
            let outcome = DebugRPCServer.performPress(identifier: "recordOnlyToggle", in: root, maxDepth: 0)
            XCTAssertEqual(outcome, .pressed(true), "the root is always inspected; maxDepth only caps descendants")
        }

        @MainActor
        func testPerformPressRespectsMaxDepth() {
            let target = FakePressTarget(identifier: "recordOnlyToggle")
            let mid = FakePressTarget(identifier: "section", children: [target])
            let root = FakePressTarget(identifier: "settings", children: [mid])

            // maxDepth 1 reaches `mid` but truncates before `target`.
            let outcome = DebugRPCServer.performPress(identifier: "recordOnlyToggle", in: root, maxDepth: 1)

            XCTAssertEqual(outcome, .notFound, "a target below the depth cap must not be found")
            XCTAssertEqual(target.pressCallCount, 0)
        }

        // MARK: - response(for:) mapping (pure)

        // The 200/404/409 arms are unreachable through route() headless (no live
        // window → 503 first), so the outcome→response mapping is tested directly.
        func testResponseForPressedIs200WithJSONBody() {
            let accepted = DebugRPCServer.response(for: .pressed(true))
            XCTAssertEqual(accepted.status, 200)
            XCTAssertEqual(accepted.contentType, "application/json")
            XCTAssertEqual(String(data: accepted.body, encoding: .utf8), #"{"pressed":true}"#)

            let declined = DebugRPCServer.response(for: .pressed(false))
            XCTAssertEqual(declined.status, 200)
            XCTAssertEqual(String(data: declined.body, encoding: .utf8), #"{"pressed":false}"#)
        }

        func testResponseForNotFoundIs404() {
            XCTAssertEqual(DebugRPCServer.response(for: .notFound).status, 404)
        }

        func testResponseForDisabledIs409() {
            XCTAssertEqual(DebugRPCServer.response(for: .disabled).status, 409)
        }

        // MARK: - payload decode (pure)

        func testUIPressPayloadDecodesWindowAndIdentifier() throws {
            let data = Data(#"{"window":"settings","identifier":"recordOnlyToggle"}"#.utf8)
            let payload = try JSONDecoder().decode(UIPressPayload.self, from: data)
            XCTAssertEqual(payload.window, "settings")
            XCTAssertEqual(payload.identifier, "recordOnlyToggle")
        }

        func testUIPressPayloadOmittedWindowIsNil() throws {
            let data = Data(#"{"identifier":"recordOnlyToggle"}"#.utf8)
            let payload = try JSONDecoder().decode(UIPressPayload.self, from: data)
            XCTAssertNil(payload.window)
            XCTAssertEqual(payload.identifier, "recordOnlyToggle")
        }

        // MARK: - allowlist (pure)

        func testIsWindowAllowedForUIPress() {
            XCTAssertTrue(DebugRPCServer.isWindowAllowedForUIPress(identifier: "settings"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUIPress(identifier: "speaker-naming"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUIPress(identifier: "record-app"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUIPress(identifier: "live-captions"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUIPress(identifier: ""))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUIPress(identifier: nil))
        }

        func testIsIdentifierAllowedForUIPress() {
            XCTAssertTrue(DebugRPCServer.isIdentifierAllowedForUIPress("recordOnlyToggle"))
            XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIPress("someOtherControl"))
            XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIPress(""))
        }

        // MARK: - route

        private func authed(_ body: String) -> HTTPRequest {
            HTTPRequest(
                method: "POST", path: "/ui/press",
                headers: ["authorization": "Bearer \(Self.testToken)"],
                body: Data(body.utf8),
            )
        }

        @MainActor
        func testRouteUIPressBadJSONReturns400() async {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(authed("not json"))
            XCTAssertEqual(response.status, 400)
        }

        @MainActor
        func testRouteUIPressEmptyIdentifierReturns400() async {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(authed(#"{"window":"settings","identifier":""}"#))
            XCTAssertEqual(response.status, 400)
        }

        @MainActor
        func testRouteUIPressDisallowedWindowReturns403() async {
            // The allowlist check precedes window resolution, so a PII window is
            // refused even when it isn't open.
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(authed(#"{"window":"speaker-naming","identifier":"x"}"#))
            XCTAssertEqual(response.status, 403)
        }

        @MainActor
        func testRouteUIPressDisallowedIdentifierReturns403() async {
            // An identifier off the press allowlist is refused even on an allowed
            // window, and before window resolution — so it's testable headless.
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(authed(#"{"window":"settings","identifier":"someOtherControl"}"#))
            XCTAssertEqual(response.status, 403)
        }

        @MainActor
        func testRouteUIPressAllowedButNoWindowReturns503() async {
            // Tests run headless — NSApp has no "settings" window, so resolution
            // returns nil and the route maps to 503 (mirrors /screenshot, /ui/tree).
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(authed(#"{"window":"settings","identifier":"recordOnlyToggle"}"#))
            XCTAssertEqual(response.status, 503)
        }

        @MainActor
        func testRouteUIPressRequiresAuth() async {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = await server.route(HTTPRequest(
                method: "POST", path: "/ui/press",
                body: Data(#"{"window":"settings","identifier":"recordOnlyToggle"}"#.utf8),
            ))
            XCTAssertEqual(response.status, 401)
        }
    }
#endif
