@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// What `AudioCaptureSession` reports about a microphone that stalled (issues
/// #724, #706), read off the session itself, so the wiring from the handler's
/// callbacks to `micCaptureStall` and `micCaptureGaveUp` is what is under test.
/// `MicCaptureStall`'s own transitions are pinned in `MicCaptureStallTests`;
/// those pass whether or not the session ever calls them.
///
/// The handler is the real one, built through the session's handler seam on
/// scripted engines and a manual clock, so the stall and the revival run
/// through the real watchdog and restart path without waiting them out.
@available(macOS 14.2, *)
@MainActor
final class AudioCaptureSessionMicStallTests: XCTestCase {
    private var factory = ScriptedSessionFactory()
    private var clock = ManualMainClock()
    private var url: URL?

    override func setUp() {
        super.setUp()
        factory = ScriptedSessionFactory()
        clock = ManualMainClock()
    }

    override func tearDown() {
        for session in factory.sessions {
            session.release()
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    /// A microphone-only session whose handler the test can drive.
    private func startSession() throws -> (AudioCaptureSession, () -> MicCaptureHandler?) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-stall-\(UUID().uuidString).wav")
        self.url = url
        let factory = factory
        let clock = clock
        var built: MicCaptureHandler?
        let makeSession: () -> any MicEngineSessionProviding = { factory.make() }
        let makeHandler: (URL) -> MicCaptureHandler = { outputURL in
            let handler = MicCaptureHandler(
                outputURL: outputURL, sessionFactory: makeSession,
                scheduleOnMain: clock.scheduler, clock: clock.reading,
            )
            built = handler
            return handler
        }
        let config = AudioCaptureConfiguration(
            pids: [], appOutputURL: nil, micOutputURL: url, sampleRate: 48000, channels: 2,
        )
        let session = AudioCaptureSession(
            config, appAttemptBody: nil, micSessionFactory: nil, micHandlerFactory: makeHandler,
        )
        try session.start()
        return (session, { built })
    }

    /// A revived microphone whose attempt wedges gives up, and the session
    /// must end the stall with it. Without that `/state` reports the
    /// microphone as released for lack of audio and lost for good at once,
    /// and the stall message stays up beside the give-up.
    func testARevivalThatWedgesEndsTheStallWithTheGiveUp() throws {
        // The first engine and its four rebuilds never deliver; the revival's
        // engine wedges inside the call that brings it up.
        factory.script([{ _ in }, { _ in }, { _ in }, { _ in }, { $0.shouldWedge = true }])
        let (session, handler) = try startSession()
        let mic = try XCTUnwrap(handler(), "the session built its handler through the seam")

        clock.advance(by: MicCaptureProgressPolicy.maxSecondsWithoutAudio) { settle(mic) }

        XCTAssertTrue(session.micCaptureStall.isActive, "stalled")
        XCTAssertEqual(session.micCaptureStall.count, 1, "once")
        XCTAssertFalse(session.micCaptureGaveUp)

        mic.handleDeviceChange()
        waitForSessions(factory, count: 6)
        let wedged = try XCTUnwrap(factory.sessions.last)
        wait(for: [wedged.entered], timeout: 5)
        settle(mic, drainingRestartQueue: false)
        clock.advance(by: 3600) { settle(mic, drainingRestartQueue: false) }

        XCTAssertTrue(session.micCaptureGaveUp, "the wedged revival gave up")
        XCTAssertFalse(session.micCaptureStall.isActive, "and the stall ended with it, not reported beside it")
        XCTAssertEqual(session.micCaptureStall.count, 1, "the stall that was told stays counted")
    }

    /// The other two callbacks, so the test above cannot pass on a session
    /// that never reported the stall at all: a stall is reported, and a
    /// revival that delivers clears it.
    func testAStallIsReportedAndARevivalThatDeliversClearsIt() throws {
        let (session, handler) = try startSession()
        let mic = try XCTUnwrap(handler())

        clock.advance(by: MicCaptureProgressPolicy.maxSecondsWithoutAudio) { settle(mic) }
        XCTAssertEqual(
            session.micCaptureStall,
            MicCaptureStall(isActive: true, count: 1, details: MicStallDetails(everDelivered: false, mayRevive: true)),
            "reported with what the stall said about itself",
        )

        mic.handleDeviceChange()
        settle(mic)
        let revived = try XCTUnwrap(factory.sessions.last)
        revived.deliver()
        clock.advance(by: MicCaptureProgressPolicy.firstBufferDeadline) { settle(mic) }

        XCTAssertFalse(session.micCaptureStall.isActive)
        XCTAssertEqual(session.micCaptureStall.count, 1)
        XCTAssertFalse(session.micCaptureGaveUp)
    }
}
