#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Unit tests for `RPCServerController`'s lifecycle — the launch gate, the
    /// settings-driven start/stop, and a fresh token for every start.
    ///
    /// Drives the controller against a spy `RPCServing` + injected enable/token
    /// closures, so the lifecycle (previously buried in `AppState` as private
    /// methods, covered only by the real-socket integration test) is testable
    /// without binding a socket.
    @MainActor
    final class RPCServerControllerTests: XCTestCase {
        private final class SpyServer: RPCServing {
            var startCount = 0
            var stopCount = 0
            func start() {
                startCount += 1
            }

            func stop() {
                stopCount += 1
            }
        }

        /// A launch with the server on must not reuse the token of an earlier
        /// run: whoever held the port while the app was not running could have
        /// collected that token from a client. The fresh token is the one the
        /// server is built with.
        func testActivateRotatesTokenAndBuildsTheServerWithIt() {
            let spy = SpyServer()
            var tokensMade = 0
            var builtWith: [String] = []
            let controller = RPCServerController(
                isEnabled: { false },
                envForceEnabled: { true },
                makeToken: {
                    tokensMade += 1
                    return "token-\(tokensMade)"
                },
            )
            controller.activate { token in
                builtWith.append(token)
                return spy
            }
            XCTAssertEqual(spy.startCount, 1, "env-forced launch should start the server")
            XCTAssertEqual(tokensMade, 1, "every server start, the launch included, must rotate the token")
            XCTAssertEqual(builtWith, ["token-1"], "the server must be built with the freshly rotated token")
            XCTAssertNotNil(controller.server)
        }

        func testActivateDoesNotStartWhenDisabledAndNotForced() {
            let spy = SpyServer()
            let controller = RPCServerController(
                isEnabled: { false },
                envForceEnabled: { false },
                makeToken: { "token" },
            )
            controller.activate { _ in spy }
            XCTAssertEqual(spy.startCount, 0)
            XCTAssertNil(controller.server)
        }

        func testApplyRotatesTokenAndStartsOnEnable() {
            let spy = SpyServer()
            var enabled = false
            var tokensMade = 0
            let controller = RPCServerController(
                isEnabled: { enabled },
                envForceEnabled: { false },
                makeToken: {
                    tokensMade += 1
                    return "token"
                },
            )
            controller.activate { _ in spy } // disabled → no start
            XCTAssertEqual(spy.startCount, 0)

            enabled = true
            controller.apply() // off → on: rotate the bearer token, then start
            XCTAssertEqual(tokensMade, 1, "off→on must rotate the bearer token")
            XCTAssertEqual(spy.startCount, 1)
            XCTAssertNotNil(controller.server)
        }

        func testApplyStopsOnDisable() {
            let spy = SpyServer()
            var enabled = true
            let controller = RPCServerController(
                isEnabled: { enabled },
                envForceEnabled: { true },
                makeToken: { "token" },
            )
            controller.activate { _ in spy } // forced → started
            XCTAssertEqual(spy.startCount, 1)

            enabled = false
            controller.apply() // on → off: stop + drop
            XCTAssertEqual(spy.stopCount, 1)
            XCTAssertNil(controller.server)
        }

        func testApplyIsNoOpWhenAlreadyRunning() {
            let spy = SpyServer()
            let controller = RPCServerController(
                isEnabled: { true },
                envForceEnabled: { true },
                makeToken: { "token" },
            )
            controller.activate { _ in spy } // started (count 1)
            controller.apply() // still enabled + server != nil → no restart
            XCTAssertEqual(spy.startCount, 1, "apply while already running must not restart")
        }

        /// Each start asks for a new token rather than reusing the first one.
        func testEveryStartBuildsTheServerWithANewToken() {
            var enabled = true
            var tokensMade = 0
            var builtWith: [String] = []
            let controller = RPCServerController(
                isEnabled: { enabled },
                envForceEnabled: { false },
                makeToken: {
                    tokensMade += 1
                    return "token-\(tokensMade)"
                },
            )
            controller.activate { token in
                builtWith.append(token)
                return SpyServer()
            }
            enabled = false
            controller.apply() // stop
            enabled = true
            controller.apply() // start again
            XCTAssertEqual(builtWith, ["token-1", "token-2"])
        }
    }
#endif
