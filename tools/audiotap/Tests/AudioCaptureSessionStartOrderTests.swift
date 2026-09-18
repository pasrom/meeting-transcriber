@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// Pins the order in which `AudioCaptureSession.start()` brings the two channels
/// up, and what each channel's failure does to the other. Why the order matters
/// is on `AudioCaptureSession.start()`.
///
/// Both handlers are driven through their own hardware seams here, so nothing in
/// this file reaches an audio device.
@available(macOS 14.2, *)
final class AudioCaptureSessionStartOrderTests: XCTestCase {
    /// What the microphone channel does. Its two failures are distinct because
    /// `MicCaptureHandler` creates its WAV part-way through starting: one leaves
    /// a file behind, the other does not.
    private enum MicSeam {
        case succeeds
        case failsBeforeCreatingItsFile
        case failsAfterCreatingItsFile
        case absent
    }

    /// What the app-audio channel does. `fileCannotBeOpened` fails before the
    /// tap, at the descriptor the tap would write to.
    private enum AppSeam {
        case succeeds
        case fails
        case fileCannotBeOpened
        case absent
    }

    /// Everything both seams did, in one list, so the assertions are about one
    /// ordering rather than separate counters that happen to agree.
    private enum Step: Equatable {
        case mic
        case app
        /// Recorded by the fake engine session. `MicCaptureHandler.deinit` also
        /// stops the handler, so this step only pins the session's own teardown
        /// while the session still holds the handler, which is the app-tap
        /// failure below. On the swallowed microphone failures it is a faithful
        /// record of what happens and nothing more: `deinit` would put the same
        /// step in the same place. Measured, not assumed.
        case micTeardown
    }

    /// Locked because `teardown()` reaches it from `MicCaptureHandler.stop()`,
    /// which `deinit` also calls, and that runs on whichever thread drops the
    /// last reference. The sanitizer lane would otherwise report the append.
    private final class StartLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Step] = []

        var steps: [Step] {
            lock.withLock { recorded }
        }

        func record(_ step: Step) {
            lock.withLock { recorded.append(step) }
        }
    }

    /// Stands in for the microphone's `AVAudioEngine`. `hardwareFormat` is the
    /// first call `MicCaptureHandler.start` makes and the one that reaches the
    /// device, so it is where the microphone's turn is recorded.
    private final class FakeMicSession: MicEngineSessionProviding {
        private let log: StartLog
        private let seam: MicSeam
        let notificationObject: AnyObject = NSObject()
        // 48 kHz mono, what a headset reports before the call profile takes it
        // down. Force-unwrapped because a standard format at a valid rate cannot
        // fail, and a fake that cannot be built is a broken test either way.
        // swiftlint:disable:next force_unwrapping
        private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

        init(log: StartLog, seam: MicSeam) {
            self.log = log
            self.seam = seam
        }

        func hardwareFormat(deviceUID _: String?) throws -> AVAudioFormat {
            log.record(.mic)
            if seam == .failsBeforeCreatingItsFile { throw SeamError() }
            return format
        }

        func installTap(format _: AVAudioFormat, block _: AVAudioNodeTapBlock) throws {
            if seam == .failsAfterCreatingItsFile { throw SeamError() }
        }

        func start() {}

        func teardown() {
            log.record(.micTeardown)
        }
    }

    /// Distinguishable from anything AVFoundation or CoreAudio would raise, and
    /// from `AudioCaptureSessionError`.
    private struct SeamError: Error {}

    private struct Fixture {
        let session: AudioCaptureSession
        let log: StartLog
        let appURL: URL
        let micURL: URL
    }

    private func makeFixture(mic: MicSeam = .succeeds, app: AppSeam = .succeeds) -> Fixture {
        let log = StartLog()
        let micSession = FakeMicSession(log: log, seam: mic)

        let stem = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
        // A path under a directory that does not exist: `createFile` fails and
        // `FileHandle(forWritingTo:)` throws, which is what an unwritable
        // staging directory or a stale security-scoped bookmark looks like.
        let appURL = app == .fileCannotBeOpened
            ? dir.appendingPathComponent("start-order-\(stem)-absent/app16k_raw.tmp")
            : dir.appendingPathComponent("start-order-\(stem)_app16k_raw.tmp")
        let micURL = dir.appendingPathComponent("start-order-\(stem)_mic.wav")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: appURL)
            try? FileManager.default.removeItem(at: micURL)
        }

        let session = AudioCaptureSession(
            AudioCaptureConfiguration(
                pids: [1],
                appOutputURL: app == .absent ? nil : appURL,
                micOutputURL: mic == .absent ? nil : micURL,
                sampleRate: 48000,
                channels: 2,
            ),
            appAttemptBody: {
                log.record(.app)
                if app == .fails { throw SeamError() }
                // Only the seam returns nothing: production `startCapture`
                // either hands back a session or throws.
                return nil
            },
            micSessionFactory: { micSession },
        )
        return Fixture(session: session, log: log, appURL: appURL, micURL: micURL)
    }

    func testStartOpensTheMicrophoneBeforeTheAppTap() throws {
        let fixture = makeFixture()

        try fixture.session.start()

        XCTAssertEqual(fixture.log.steps, [.mic, .app])
        // Control for the two file-removal assertions below: a microphone that
        // gets as far as its tap really does leave a file behind, so an absent
        // one there is a deletion and not a file never written.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.micURL.path))
        _ = fixture.session.stop()
    }

    func testAnAppOnlySessionOpensNoMicrophone() throws {
        let fixture = makeFixture(mic: .absent)

        try fixture.session.start()

        XCTAssertEqual(fixture.log.steps, [.app])
        // Nothing asserted about the result's mic URL: `AudioCaptureResult.make`
        // returns nil for it whenever no mic track was configured, so it would
        // hold with the microphone open too.
        _ = fixture.session.stop()
    }

    /// Trap in the reorder: the swallow used to be conditional on an app capture
    /// already running, which after the move is never true. It has to key on the
    /// app track being *requested* instead.
    func testMicrophoneFailureStillBringsTheAppTapUp() throws {
        let fixture = makeFixture(mic: .failsBeforeCreatingItsFile)

        XCTAssertNoThrow(try fixture.session.start())

        XCTAssertEqual(fixture.log.steps, [.mic, .micTeardown, .app])
        XCTAssertNil(fixture.session.stop().micAudioFileURL)
    }

    /// The other arm of the same trap: with no app track the microphone IS the
    /// recording, so swallowing its failure would report success for a session
    /// that captures nothing.
    func testMicrophoneFailureWithoutAnAppTrackIsTerminal() {
        let fixture = makeFixture(mic: .failsBeforeCreatingItsFile, app: .absent)

        XCTAssertThrowsError(try fixture.session.start()) { error in
            XCTAssertTrue(error is SeamError, "the device's own error, not a session-level one")
        }
        XCTAssertEqual(fixture.log.steps, [.mic, .micTeardown])
    }

    /// A microphone can fail after it has created its WAV, and a swallowed
    /// failure must not leave that file behind: nothing downstream reads a track
    /// the result does not report, and nothing collects it either.
    func testASwallowedMicrophoneFailureLeavesNoFileBehind() throws {
        let fixture = makeFixture(mic: .failsAfterCreatingItsFile)

        XCTAssertNoThrow(try fixture.session.start())

        XCTAssertEqual(fixture.log.steps, [.mic, .micTeardown, .app])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.micURL.path))
        XCTAssertNil(fixture.session.stop().micAudioFileURL)
    }

    /// Trap in the reorder: a tap failure now has a running microphone behind it.
    /// This is the one place the teardown step pins the session rather than
    /// `deinit`: remove the discard and the session still holds the handler when
    /// `start()` throws, so no teardown is recorded at all.
    ///
    /// `withExtendedLifetime` is inert against the code as it stands, since the
    /// teardown is recorded synchronously inside `start()` and a later `deinit`
    /// adds nothing (the handler's stop is idempotent). It is there for the
    /// mutated run that proves this test discriminates: without the discard, an
    /// optimised build could release the fixture between evaluating `fixture.log`
    /// and reading `steps`, and `deinit` would then supply the missing step.
    func testAppTapFailureStopsTheMicrophone() {
        let fixture = makeFixture(app: .fails)

        XCTAssertThrowsError(try fixture.session.start())

        withExtendedLifetime(fixture) {
            XCTAssertEqual(fixture.log.steps, [.mic, .app, .micTeardown])
        }
    }

    /// A failed start must leave nothing behind. Nothing downstream reads a
    /// microphone track the result does not report, and no cleanup pass collects
    /// one either.
    func testAppTapFailureRemovesTheMicrophoneFile() {
        let fixture = makeFixture(app: .fails)

        XCTAssertThrowsError(try fixture.session.start())

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.micURL.path))
    }

    /// The other half of leaving nothing behind, and the more expensive half: a
    /// raw app temp with no mix beside it is the crashed-recording signature, so
    /// an empty one would be picked up at the next launch, fail to recover, and
    /// be reported as a lost recording.
    func testAppTapFailureRemovesTheAppTempFile() {
        let fixture = makeFixture(app: .fails)

        XCTAssertThrowsError(try fixture.session.start())

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appURL.path))
    }

    /// The arm that runs for every app-only recording whose tap fails: there is
    /// no microphone to stop, and the teardown has to cope with that.
    func testAppTapFailureWithNoMicrophoneLeavesNothingBehind() {
        let fixture = makeFixture(mic: .absent, app: .fails)

        XCTAssertThrowsError(try fixture.session.start())

        XCTAssertEqual(fixture.log.steps, [.app])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appURL.path))
    }

    /// The app track's file is opened before the microphone, so a session that
    /// cannot write it never touches the input device. That ordering is not
    /// cosmetic: on a first run, opening the input is what raises the microphone
    /// permission prompt and lights the recording indicator, and asking for that
    /// on behalf of a recording that is about to fail is a poor trade.
    func testAnUnwritableAppPathFailsBeforeTheMicrophoneIsOpened() {
        let fixture = makeFixture(app: .fileCannotBeOpened)

        XCTAssertThrowsError(try fixture.session.start())

        XCTAssertEqual(fixture.log.steps, [], "neither channel was reached")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.micURL.path))
    }

    /// The cleanup removes only a path that was free when the start reached it.
    /// That covers a failure before the handler opens its WAV, which is the arm
    /// exercised here; past that point the handler has truncated the file anyway,
    /// and what survives is a husk rather than the caller's recording.
    func testAFileAlreadyAtTheMicrophonePathSurvivesAFailedStart() throws {
        let fixture = makeFixture(mic: .failsBeforeCreatingItsFile)
        let existing = Data("not ours to delete".utf8)
        try existing.write(to: fixture.micURL)

        XCTAssertNoThrow(try fixture.session.start())

        XCTAssertEqual(try Data(contentsOf: fixture.micURL), existing)
        _ = fixture.session.stop()
    }
}
