@testable import AudioTapLib
import XCTest

/// The restart path's own timers, the retry backoff and the attempt deadline
/// from issue #588, driven on a manual clock instead of waited out.
///
/// `MicCaptureHandlerWedgeTests` covers the same paths on the real clock; these
/// exist so every path can be driven to its end deterministically, including
/// the ones a longer test would otherwise have to sleep through.
@MainActor
final class MicCaptureRestartTimerTests: XCTestCase {
    private var factory = ScriptedSessionFactory()
    private var clock = ManualMainClock()
    private var gaveUp = 0
    private var url: URL?

    private var sessions: [ScriptedMicSession] {
        factory.sessions
    }

    override func setUp() {
        super.setUp()
        factory = ScriptedSessionFactory()
        clock = ManualMainClock()
        gaveUp = 0
    }

    override func tearDown() {
        for session in sessions {
            session.release()
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    /// The first session is the one `start()` uses; `script` configures the
    /// sessions restart attempts build after it, in order.
    private func makeHandler() throws -> MicCaptureHandler {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("timers-\(UUID().uuidString).wav")
        self.url = url
        // Typed locals, not trailing closures: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
        let factory = factory
        let makeSession: () -> any MicEngineSessionProviding = { factory.make() }
        let handler = MicCaptureHandler(
            outputURL: url, sessionFactory: makeSession, scheduleOnMain: clock.scheduler,
        )
        handler.onGiveUp = { [weak self] in self?.gaveUp += 1 }
        try handler.start()
        return handler
    }

    // MARK: - Retry backoff

    func testAFailedAttemptIsRetriedAfterItsBackoffOnTheInjectedClock() throws {
        factory.script([{ $0.shouldThrow = true }])
        let handler = try makeHandler()

        handler.handleDeviceChange()
        settle(handler)
        XCTAssertEqual(sessions.count, 2, "the attempt ran and failed")

        clock.advance(by: CaptureRestartRetryPolicy.baseBackoff - 0.01) { settle(handler) }
        XCTAssertEqual(sessions.count, 2, "still backing off")
        clock.advance(by: 0.02) { settle(handler) }
        XCTAssertEqual(sessions.count, 3, "retried once the backoff elapsed")
        XCTAssertTrue(handler.isRecording, "and the retry was adopted")
        XCTAssertEqual(sessions[0].teardowns, 1, "released by the attempt that failed, not again by its retry")
    }

    func testRetriesThatAllFailGiveUpOnce() throws {
        factory.script(Array(repeating: { $0.shouldThrow = true }, count: CaptureRestartRetryPolicy.maxAttempts + 1))
        let handler = try makeHandler()

        handler.handleDeviceChange()
        settle(handler)
        clock.advance(by: 60) { settle(handler) }

        XCTAssertEqual(gaveUp, 1)
        XCTAssertEqual(sessions.count, 2 + CaptureRestartRetryPolicy.maxAttempts)
        XCTAssertFalse(handler.arbiter.withLock { $0.mayCreateOutputFile })
    }

    // MARK: - The attempt deadline (#588)

    func testAWedgedAttemptGivesUpAtItsDeadlineOnTheInjectedClock() throws {
        factory.script([{ $0.shouldWedge = true }])
        let handler = try makeHandler()

        handler.handleDeviceChange()
        waitForSessions(factory, count: 2)
        let wedged = try XCTUnwrap(sessions.last)
        wait(for: [wedged.entered], timeout: 5)
        // It armed its deadline on the main queue before it wedged.
        settle(handler, drainingRestartQueue: false)

        clock.advance(by: RestartArbiter.attemptTimeout - 0.01) { settle(handler, drainingRestartQueue: false) }
        XCTAssertEqual(gaveUp, 0, "the deadline has not passed")
        clock.advance(by: 0.02) { settle(handler, drainingRestartQueue: false) }
        XCTAssertEqual(gaveUp, 1)
        XCTAssertEqual(wedged.teardowns, 0, "the wedged engine is never touched")
    }

    func testAStopDuringAWedgedAttemptLeavesItsEngineAloneAndGivesNothingUp() throws {
        factory.script([{ $0.shouldWedge = true }])
        let handler = try makeHandler()

        handler.handleDeviceChange()
        waitForSessions(factory, count: 2)
        let wedged = try XCTUnwrap(sessions.last)
        wait(for: [wedged.entered], timeout: 5)
        // It armed its deadline on the main queue before it wedged.
        settle(handler, drainingRestartQueue: false)

        handler.stop()
        clock.advance(by: 60) { settle(handler, drainingRestartQueue: false) }

        XCTAssertEqual(gaveUp, 0, "a stop is not a lost channel")
        XCTAssertEqual(wedged.teardowns, 0)
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .stopped)
    }
}
