#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Unit tests for `RPCServerController`'s lifecycle — the launch gate, the
    /// settings-driven start/stop, and the security token rotation on re-enable.
    ///
    /// Drives the controller against a spy `RPCServing` + injected enable/rotate
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

        func testActivateStartsWhenEnvForcedWithoutTokenRotation() {
            let spy = SpyServer()
            var rotations = 0
            let controller = RPCServerController(
                isEnabled: { false },
                envForceEnabled: { true },
                rotateToken: { rotations += 1 },
            )
            controller.activate { spy }
            XCTAssertEqual(spy.startCount, 1, "env-forced launch should start the server")
            XCTAssertEqual(rotations, 0, "the launch gate must NOT rotate the token")
            XCTAssertNotNil(controller.server)
        }

        func testActivateDoesNotStartWhenDisabledAndNotForced() {
            let spy = SpyServer()
            let controller = RPCServerController(
                isEnabled: { false },
                envForceEnabled: { false },
                rotateToken: {},
            )
            controller.activate { spy }
            XCTAssertEqual(spy.startCount, 0)
            XCTAssertNil(controller.server)
        }

        func testApplyRotatesTokenAndStartsOnEnable() {
            let spy = SpyServer()
            var enabled = false
            var rotations = 0
            let controller = RPCServerController(
                isEnabled: { enabled },
                envForceEnabled: { false },
                rotateToken: { rotations += 1 },
            )
            controller.activate { spy } // disabled → no start
            XCTAssertEqual(spy.startCount, 0)

            enabled = true
            controller.apply() // off → on: rotate the bearer token, then start
            XCTAssertEqual(rotations, 1, "off→on must rotate the bearer token")
            XCTAssertEqual(spy.startCount, 1)
            XCTAssertNotNil(controller.server)
        }

        func testApplyStopsOnDisable() {
            let spy = SpyServer()
            var enabled = true
            let controller = RPCServerController(
                isEnabled: { enabled },
                envForceEnabled: { true },
                rotateToken: {},
            )
            controller.activate { spy } // forced → started
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
                rotateToken: {},
            )
            controller.activate { spy } // started (count 1)
            controller.apply() // still enabled + server != nil → no restart
            XCTAssertEqual(spy.startCount, 1, "apply while already running must not restart")
        }
    }
#endif
