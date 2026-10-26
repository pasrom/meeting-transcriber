@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// What `AudioCaptureSession` makes of a microphone whose first start did not
/// return in time (issue #778). With an app track the recording goes on
/// without the microphone, and the session says why, because the usual
/// reading of a missing microphone ("check the device") is the wrong advice
/// for a call into the audio system that never came back. Without an app
/// track the microphone is the recording, so the timeout is thrown.
///
/// The handler is the real one, on a session that wedges and a wait that
/// gives up at once, so these do not spend the real deadline.
@available(macOS 14.2, *)
@MainActor
final class AudioCaptureSessionFirstStartTimeoutTests: XCTestCase {
    private var engines: [ScriptedMicSession] = []
    private var urls: [URL] = []

    override func setUp() {
        super.setUp()
        engines = []
        urls = []
    }

    override func tearDown() {
        for engine in engines {
            engine.release()
        }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        super.tearDown()
    }

    /// `waitsForTheStart: false` gives up at once, which with a wedging engine
    /// is a timed-out start without spending the deadline.
    private func makeSession(
        withAppTrack: Bool,
        engine: ScriptedMicSession,
        waitsForTheStart: Bool = false,
    ) -> AudioCaptureSession {
        engines.append(engine)
        let stem = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
        let micURL = dir.appendingPathComponent("first-start-\(stem)_mic.wav")
        let appURL = dir.appendingPathComponent("first-start-\(stem)_app16k_raw.tmp")
        urls += [micURL, appURL]
        let makeEngine: () -> any MicEngineSessionProviding = { engine }
        let giveUpAtOnce: @Sendable (DispatchGroup, TimeInterval) -> Bool = { _, _ in false }
        let waitForTheStart: @Sendable (DispatchGroup, TimeInterval) -> Bool = { done, _ in
            done.wait()
            return true
        }
        let makeHandler: (URL) -> MicCaptureHandler = { outputURL in
            MicCaptureHandler(
                outputURL: outputURL, sessionFactory: makeEngine,
                awaitFirstStart: waitsForTheStart ? waitForTheStart : giveUpAtOnce,
            )
        }
        let config = AudioCaptureConfiguration(
            pids: [1], appOutputURL: withAppTrack ? appURL : nil, micOutputURL: micURL,
            sampleRate: 48000, channels: 2,
        )
        return AudioCaptureSession(
            config, appAttemptBody: { nil }, micSessionFactory: nil, micHandlerFactory: makeHandler,
        )
    }

    func testATimedOutFirstStartContinuesWithTheAppTrackAndSaysWhy() throws {
        let engine = ScriptedMicSession()
        engine.shouldWedge = true
        let session = makeSession(withAppTrack: true, engine: engine)

        XCTAssertNoThrow(try session.start(), "the app track is still worth recording")

        XCTAssertTrue(session.micCaptureStartTimedOut)
        XCTAssertTrue(session.micCaptureGaveUp, "the microphone is gone for this recording")
        XCTAssertNil(session.stop().micAudioFileURL)
    }

    func testATimedOutFirstStartWithoutAnAppTrackIsThrown() {
        let engine = ScriptedMicSession()
        engine.shouldWedge = true
        let session = makeSession(withAppTrack: false, engine: engine)

        XCTAssertThrowsError(try session.start()) { error in
            guard case .firstStartTimedOut = error as? MicCaptureError else {
                return XCTFail("expected firstStartTimedOut, got \(error)")
            }
        }
    }

    /// Control: a microphone that fails and says so is not reported as one
    /// that hung, nor as one that gave up, which is the silence path's job.
    func testAFailedFirstStartIsNotReportedAsATimeout() throws {
        let engine = ScriptedMicSession()
        engine.shouldThrow = true
        let session = makeSession(withAppTrack: true, engine: engine, waitsForTheStart: true)

        XCTAssertNoThrow(try session.start())

        XCTAssertFalse(session.micCaptureStartTimedOut)
        XCTAssertFalse(session.micCaptureGaveUp)
        _ = session.stop()
    }
}
