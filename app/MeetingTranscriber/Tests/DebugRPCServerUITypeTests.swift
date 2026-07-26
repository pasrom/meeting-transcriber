#if !APPSTORE
    import AppKit
    @testable import MeetingTranscriber
    import XCTest

    /// Unit tests for the `POST /ui/type` text-entry endpoint. The pure
    /// depth-first search / dispatch / payload decode / allowlist / response
    /// mapping are exercised with an in-memory target; the AppKit half (AX focus
    /// plus the posted key events actually reaching the field) is covered at the
    /// mechanism layer by `KeyboardInjectionTests`, mirroring how `/ui/press`
    /// splits its pure search from the live press.
    final class DebugRPCServerUITypeTests: XCTestCase {
        private static let testToken = "testtoken1234"

        /// In-memory `UITypeTarget` recording what it was asked to type, so a test
        /// can prove the disabled path never types.
        @MainActor
        private final class FakeTypeTarget: UITypeTarget {
            var uiIdentifier: String?
            var uiEnabled: Bool
            var uiChildren: [any UITypeTarget]
            let typeReturns: Bool
            private(set) var typedText: [String] = []
            private(set) var clearRequests: [Bool] = []

            init(
                identifier: String? = nil, enabled: Bool = true,
                typeReturns: Bool = true, children: [any UITypeTarget] = [],
            ) {
                uiIdentifier = identifier
                uiEnabled = enabled
                self.typeReturns = typeReturns
                uiChildren = children
            }

            func uiType(_ text: String, clear: Bool) -> Bool {
                typedText.append(text)
                clearRequests.append(clear)
                return typeReturns
            }
        }

        // MARK: - performType (pure search + dispatch)

        @MainActor
        func testPerformTypeDeliversTextToEnabledMatch() {
            let field = FakeTypeTarget(identifier: A11yID.micNameField)
            let root = FakeTypeTarget(identifier: "settings", children: [field])

            let outcome = DebugRPCServer.performType(
                text: "Speaker A", identifier: A11yID.micNameField, in: root, maxDepth: 10,
            )

            XCTAssertEqual(outcome, .typed(true))
            XCTAssertEqual(field.typedText, ["Speaker A"], "the matched field must receive the text exactly once")
        }

        /// A disabled field is never typed into: the endpoint reports the conflict
        /// instead of silently dropping keystrokes into a control the user could
        /// not have typed into either.
        @MainActor
        func testPerformTypeSkipsDisabledMatch() {
            let field = FakeTypeTarget(identifier: A11yID.micNameField, enabled: false)
            let root = FakeTypeTarget(identifier: "settings", children: [field])

            let outcome = DebugRPCServer.performType(
                text: "x", identifier: A11yID.micNameField, in: root, maxDepth: 10,
            )

            XCTAssertEqual(outcome, .disabled)
            XCTAssertTrue(field.typedText.isEmpty, "a disabled field must never be typed into")
        }

        @MainActor
        func testPerformTypeReportsMissingIdentifier() {
            let root = FakeTypeTarget(identifier: "settings", children: [FakeTypeTarget(identifier: "other")])

            let outcome = DebugRPCServer.performType(
                text: "x", identifier: A11yID.micNameField, in: root, maxDepth: 10,
            )

            XCTAssertEqual(outcome, .notFound)
        }

        /// The depth cap bounds the walk: a field deeper than `maxDepth` is not
        /// reached, so a pathological tree cannot hang the handler.
        @MainActor
        func testPerformTypeRespectsDepthCap() {
            let deep = FakeTypeTarget(identifier: A11yID.micNameField)
            let root = FakeTypeTarget(identifier: "settings", children: [
                FakeTypeTarget(identifier: "a", children: [FakeTypeTarget(identifier: "b", children: [deep])]),
            ])

            let outcome = DebugRPCServer.performType(
                text: "x", identifier: A11yID.micNameField, in: root, maxDepth: 1,
            )

            XCTAssertEqual(outcome, .notFound)
            XCTAssertTrue(deep.typedText.isEmpty)
        }

        /// `clear` reaches the field: a driver asserting an exact value needs the
        /// replace path, otherwise the result depends on the field's prior text.
        @MainActor
        func testPerformTypeForwardsClearRequest() {
            let field = FakeTypeTarget(identifier: A11yID.micNameField)
            let root = FakeTypeTarget(identifier: "settings", children: [field])

            _ = DebugRPCServer.performType(
                text: "x", identifier: A11yID.micNameField, in: root, maxDepth: 10, clear: true,
            )

            XCTAssertEqual(field.clearRequests, [true])
        }

        /// Appending is the default, so a bare request never destroys existing text.
        @MainActor
        func testPerformTypeDefaultsToAppending() {
            let field = FakeTypeTarget(identifier: A11yID.micNameField)
            let root = FakeTypeTarget(identifier: "settings", children: [field])

            _ = DebugRPCServer.performType(
                text: "x", identifier: A11yID.micNameField, in: root, maxDepth: 10,
            )

            XCTAssertEqual(field.clearRequests, [false])
        }

        // MARK: - Allowlists

        /// The allowlist is the endpoint's real guard: without it any current or
        /// future field in the window could be written to over HTTP.
        func testOnlyAllowlistedIdentifiersMayBeTyped() {
            XCTAssertTrue(DebugRPCServer.isIdentifierAllowedForUIType(A11yID.micNameField))
            XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIType(A11yID.recordOnlyToggle))
            XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIType("openAIApiKeyField"))
        }

        func testOnlySettingsWindowMayBeTyped() {
            XCTAssertTrue(DebugRPCServer.isWindowAllowedForUIType(identifier: "settings"))
            XCTAssertFalse(DebugRPCServer.isWindowAllowedForUIType(identifier: "speaker-naming"))
        }

        // MARK: - Response mapping

        func testResponseMapsOutcomesToStatusCodes() {
            XCTAssertEqual(DebugRPCServer.uiTypeResponse(for: UITypeOutcome.notFound).status, 404)
            XCTAssertEqual(DebugRPCServer.uiTypeResponse(for: UITypeOutcome.disabled).status, 409)
            XCTAssertEqual(DebugRPCServer.uiTypeResponse(for: UITypeOutcome.typed(true)).status, 200)
        }

        func testTypedResponseCarriesTheWireShape() throws {
            let response = DebugRPCServer.uiTypeResponse(for: UITypeOutcome.typed(true))
            let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
            XCTAssertTrue(
                body.contains("\"dispatched\":true"),
                "the wire flag is deliberately named for dispatch, not effect; got \(body)",
            )
        }

        // MARK: - Payload decoding

        /// The hand-rolled decoder must default `clear` to append, so an omitted
        /// flag never silently replaces a field's contents.
        func testOmittedClearDecodesAsAppend() throws {
            let body = Data(#"{"identifier":"micNameField","text":"x"}"#.utf8)

            let payload = try JSONDecoder().decode(UITypePayload.self, from: body)

            XCTAssertFalse(payload.clear)
            XCTAssertNil(payload.window, "an omitted window falls back to the default at the call site")
        }

        func testExplicitClearDecodes() throws {
            let body = Data(#"{"identifier":"micNameField","text":"x","clear":true}"#.utf8)

            XCTAssertTrue(try JSONDecoder().decode(UITypePayload.self, from: body).clear)
        }

        // MARK: - Routing

        /// `/ui/type` reaches its handler through `routeUI`, so these go through
        /// `route()` rather than calling the handler directly: the dispatch branch
        /// is exactly what a duplicate or mis-ordered route would break.
        private func authed(_ body: String) -> HTTPRequest {
            HTTPRequest(
                method: "POST", path: "/ui/type",
                headers: ["authorization": "Bearer \(Self.testToken)"],
                body: Data(body.utf8),
            )
        }

        @MainActor
        func testRouteReachesTheTypeHandler() async {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }

            // 403 proves the request reached the handler's allowlist check; an
            // unrouted path would 404 instead.
            let response = await server.route(authed(#"{"identifier":"openAIApiKeyField","text":"x"}"#))

            XCTAssertEqual(response.status, 403)
        }

        @MainActor
        func testRouteRejectsMalformedTypeBody() async {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }

            let response = await server.route(authed("not json"))

            XCTAssertEqual(response.status, 400)
        }

        /// Text past the cap is refused before any window work. The cap exists so a
        /// single request cannot occupy the main actor typing tens of thousands of
        /// characters, which would stall the UI and the server with it.
        @MainActor
        func testRouteRejectsOversizedText() async {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let tooLong = String(repeating: "x", count: DebugRPCServer.uiTypeMaxTextLength + 1)

            let response = await server.route(authed(#"{"identifier":"micNameField","text":"\#(tooLong)"}"#))

            XCTAssertEqual(response.status, 400)
        }

        @MainActor
        func testTextAtTheCapIsAccepted() async {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let atCap = String(repeating: "x", count: DebugRPCServer.uiTypeMaxTextLength)

            let response = await server.route(authed(#"{"identifier":"micNameField","text":"\#(atCap)"}"#))

            // 503: allowed and correctly sized, but this process has no live window.
            XCTAssertEqual(response.status, 503, "the cap must be inclusive")
        }

        // MARK: - Headless resolution

        /// Fail closed: with no running application there is no window to focus or
        /// post into, so resolution yields nothing rather than a half-usable target.
        @MainActor
        func testTargetResolutionYieldsNothingWithoutAnApplication() {
            XCTAssertNil(NSApp, "precondition: xctest has no NSApplication")

            XCTAssertNil(DebugRPCServer.uiTypeTarget(forWindowIdentifier: "settings"))
            XCTAssertNil(DebugRPCServer.nsWindow(forIdentifier: "settings"))
        }

        // MARK: - Payload validation

        @MainActor
        func testRejectsUndecodableOrEmptyPayloads() {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }

            XCTAssertEqual(server.uiTypeResponse(body: Data("not json".utf8)).status, 400)
            XCTAssertEqual(
                server.uiTypeResponse(body: Data(#"{"identifier":"","text":"x"}"#.utf8)).status, 400,
                "an empty identifier has no target",
            )
        }

        /// Off-allowlist requests are rejected before any window lookup, so the
        /// 403 holds even in the headless test harness where no window exists.
        @MainActor
        func testRejectsOffAllowlistRequests() {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }

            let body = #"{"identifier":"openAIApiKeyField","text":"secret"}"#
            XCTAssertEqual(server.uiTypeResponse(body: Data(body.utf8)).status, 403)

            let wrongWindow = #"{"window":"speaker-naming","identifier":"micNameField","text":"x"}"#
            XCTAssertEqual(server.uiTypeResponse(body: Data(wrongWindow.utf8)).status, 403)
        }
    }
#endif
