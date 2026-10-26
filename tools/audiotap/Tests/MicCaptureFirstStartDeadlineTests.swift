@testable import AudioTapLib
@preconcurrency import AVFoundation
import os
import XCTest

/// The microphone's first start under a deadline (issue #778).
///
/// The first engine used to be brought up on the main queue with no bound at
/// all, so the wedge a restart is protected against (issue #588) froze the
/// whole app when it struck a first start instead. Now it runs on the restart
/// queue and the main queue waits for it for `RestartArbiter.attemptTimeout`,
/// plus at most `MicCaptureHandler.firstStartReportGrace` when the deadline
/// and the attempt's report cross.
///
/// The deadline tests read the wall clock, not a manual one advanced to the
/// end: what is being pinned is when `start()` actually returns.
final class MicCaptureFirstStartDeadlineTests: XCTestCase {
    /// A session that can wedge inside `hardwareFormat` while holding the
    /// engine mutex `teardown` also takes, like the real wedge. It lets go by
    /// itself after `safetyRelease`, so a regression that waits forever fails
    /// the test rather than hanging the suite.
    private final class FirstStartSession: MicEngineSessionProviding, @unchecked Sendable {
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let notificationObject: AnyObject = NSObject()
        var shouldWedge = false
        /// Wedge in `installTap` instead, after the output file step.
        var shouldWedgeInInstallTap = false
        /// Signalled once `installTap` was entered.
        let installingTap = DispatchSemaphore(value: 0)
        /// Signalled once a wedging `hardwareFormat` was entered.
        let enteringFormat = DispatchSemaphore(value: 0)
        var shouldThrow = false
        let safetyRelease: TimeInterval = 12

        private let lock = NSLock()
        private let engineMutex = NSLock()
        private let wedge = DispatchSemaphore(value: 0)
        private var storedTeardowns = 0
        private var storedStarts = 0
        private var storedEngineCallsOnMain = 0
        private var storedEngineCallsOffMain = 0
        private var storedTapBlock: AVAudioNodeTapBlock?

        var teardowns: Int {
            lock.withLock { storedTeardowns }
        }

        var starts: Int {
            lock.withLock { storedStarts }
        }

        /// How often the call that can wedge ran on the main thread, and off it.
        var engineCallsOnMain: Int {
            lock.withLock { storedEngineCallsOnMain }
        }

        var engineCallsOffMain: Int {
            lock.withLock { storedEngineCallsOffMain }
        }

        var tapBlock: AVAudioNodeTapBlock? {
            lock.withLock { storedTapBlock }
        }

        func release() {
            wedge.signal()
        }

        func hardwareFormat(deviceUID _: String?) throws -> AVAudioFormat {
            let onMain = Thread.isMainThread
            lock.withLock {
                if onMain { storedEngineCallsOnMain += 1 } else { storedEngineCallsOffMain += 1 }
            }
            if shouldThrow { throw MicCaptureError.noInputDevice }
            if shouldWedge {
                engineMutex.lock()
                defer { engineMutex.unlock() }
                enteringFormat.signal()
                _ = wedge.wait(timeout: .now() + safetyRelease)
            }
            return format
        }

        func installTap(format _: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
            lock.withLock { storedTapBlock = block }
            installingTap.signal()
            if shouldWedgeInInstallTap {
                engineMutex.lock()
                defer { engineMutex.unlock() }
                _ = wedge.wait(timeout: .now() + safetyRelease)
            }
        }

        func start() {
            lock.withLock { storedStarts += 1 }
        }

        func teardown() {
            engineMutex.lock()
            defer { engineMutex.unlock() }
            lock.withLock { storedTeardowns += 1 }
        }
    }

    private var urls: [URL] = []

    override func setUp() {
        super.setUp()
        urls = []
    }

    override func tearDown() {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        super.tearDown()
    }

    private func makeHandler(
        _ session: FirstStartSession,
        clock: ManualMainClock = ManualMainClock(),
        awaitFirstStart: (@Sendable (DispatchGroup, TimeInterval) -> Bool)? = nil,
        giveUpOnceWedged: Bool = false,
    ) -> (MicCaptureHandler, URL) {
        // Gives up only once the attempt sits in the wedging `hardwareFormat`.
        // An attempt whose block has not begun yet stops at its first check
        // instead, which is a different path from the one these tests mean.
        let onceWedged: @Sendable (DispatchGroup, TimeInterval) -> Bool = { _, _ in
            session.enteringFormat.wait()
            return false
        }
        let awaitFirstStart = giveUpOnceWedged ? onceWedged : awaitFirstStart
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-start-\(UUID().uuidString).wav")
        urls.append(url)
        // Typed local, not a trailing closure: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
        let factory: () -> any MicEngineSessionProviding = { session }
        guard let awaitFirstStart else {
            let handler = MicCaptureHandler(
                outputURL: url, sessionFactory: factory,
                scheduleOnMain: clock.scheduler, clock: clock.reading,
            )
            return (handler, url)
        }
        let handler = MicCaptureHandler(
            outputURL: url, sessionFactory: factory,
            scheduleOnMain: clock.scheduler, clock: clock.reading,
            awaitFirstStart: awaitFirstStart,
        )
        return (handler, url)
    }

    // MARK: - The deadline, on the wall clock

    func testAWedgedFirstStartReturnsAtTheDeadline() throws {
        let session = FirstStartSession()
        session.shouldWedge = true
        let (handler, _) = makeHandler(session)
        defer { session.release() }

        let began = Date()
        XCTAssertThrowsError(try handler.start()) { error in
            guard case .firstStartTimedOut = error as? MicCaptureError else {
                return XCTFail("expected firstStartTimedOut, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertGreaterThanOrEqual(
            elapsed, RestartArbiter.attemptTimeout - 0.05,
            "the first start must get its whole deadline before it is given up",
        )
        // A quarter second of slack for a loaded machine. A group wait wakes
        // within milliseconds of its deadline; the slack covers the main
        // thread being scheduled late under a parallel run, and a deadline
        // more than that too long still fails.
        XCTAssertLessThan(
            elapsed, RestartArbiter.attemptTimeout + 0.25,
            "the main thread must stop waiting at the deadline, not when the wedge lets go",
        )
        XCTAssertEqual(session.engineCallsOnMain, 0, "the call that can wedge must not run on the main thread")
        XCTAssertEqual(session.engineCallsOffMain, 1)
        XCTAssertFalse(handler.isRecording)
    }

    /// What a microphone-only recording shows as its error: only what was
    /// observed, the microphone not answering within the deadline and the
    /// recording not starting. No remedy: that restarting the app clears the
    /// call is not measured. Pinned whole, so an added claim fails too.
    func testTheTimeoutErrorSaysOnlyWhatWasObserved() {
        XCTAssertEqual(MicStartLimits.firstStartDeadlineSeconds, Int(RestartArbiter.attemptTimeout))
        XCTAssertEqual(
            MicCaptureError.firstStartTimedOut.errorDescription,
            "The microphone did not respond within 5 seconds of being opened, so the recording could not start.",
        )
    }

    /// The production wait is the one the wall-clock test above measures;
    /// this pins that the handler hands it the arbiter's deadline.
    func testTheWaitIsGivenTheArbitersDeadline() throws {
        let session = FirstStartSession()
        let asked = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
        let (handler, _) = makeHandler(session) { done, timeout in
            asked.withLock { $0.append(timeout) }
            done.wait()
            return true
        }

        try handler.start()

        XCTAssertEqual(asked.withLock { $0 }, [RestartArbiter.attemptTimeout])
        handler.stop()
    }

    // MARK: - After the deadline

    /// The wedged call returns later, as the one in the field did when its
    /// device came back. It must not create the recording's file, start
    /// capturing or leave its engine running; and a stop meanwhile must not
    /// touch the engine it is stuck in, or the stop wedges too.
    func testAFirstStartThatReturnsAfterTheDeadlineLeavesNothingBehind() throws {
        let session = FirstStartSession()
        session.shouldWedge = true
        let (handler, url) = makeHandler(session, giveUpOnceWedged: true)

        XCTAssertThrowsError(try handler.start())

        let stopBegan = Date()
        handler.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopBegan), 1, "a stop must not wait for the wedged engine")
        XCTAssertEqual(session.teardowns, 0, "a stop must leave the wedged engine alone")

        session.release()
        handler.restartQueue.sync {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a late return must not create the file")
        XCTAssertFalse(handler.isRecording)
        // Opening the input is what moves a Bluetooth headset into its call
        // profile (issue #693); a late return doing it would do so under the
        // app tap the recording went on with, or in a later recording.
        XCTAssertNil(session.tapBlock, "a late return must not install a tap")
        XCTAssertEqual(session.starts, 0, "a late return must not open the input")
        XCTAssertEqual(session.teardowns, 1, "the late return must release the engine it brought up")
    }

    /// The same, for a start that got past the format and wedged installing
    /// its tap: it must still not go on to open the input.
    func testAFirstStartThatWedgedInstallingItsTapDoesNotOpenTheInputLater() throws {
        let session = FirstStartSession()
        session.shouldWedgeInInstallTap = true
        // Give up only once the attempt is past the check before the tap, or
        // that check, not the one before the start, is what stops it.
        let (handler, _) = makeHandler(session) { _, _ in
            session.installingTap.wait()
            return false
        }

        XCTAssertThrowsError(try handler.start())
        handler.stop()
        session.release()
        handler.restartQueue.sync {}

        XCTAssertEqual(session.starts, 0, "a late return must not open the input")
        XCTAssertEqual(session.teardowns, 1, "the late return must release the engine it brought up")
    }

    /// Nothing may be armed for a capture that never started: no progress
    /// check that would rebuild an engine the arbiter has given up on, and
    /// no observer that would restart it on the next device change.
    func testATimedOutFirstStartArmsNothing() throws {
        let session = FirstStartSession()
        session.shouldWedge = true
        let clock = ManualMainClock()
        let (handler, _) = makeHandler(session, clock: clock, giveUpOnceWedged: true)
        defer { session.release() }

        XCTAssertThrowsError(try handler.start())

        XCTAssertEqual(clock.pendingCount, 0, "a timed-out first start must schedule no progress check")
        XCTAssertNil(handler.configChangeObserver, "a timed-out first start must not observe the engine")
    }

    // MARK: - Within the deadline

    func testAHealthyFirstStartIsAdoptedAndWatched() throws {
        let session = FirstStartSession()
        let clock = ManualMainClock()
        let (handler, _) = makeHandler(session, clock: clock)

        try handler.start()

        XCTAssertTrue(handler.isRecording)
        XCTAssertEqual(session.engineCallsOnMain, 0, "the engine must come up off the main thread")
        XCTAssertEqual(session.engineCallsOffMain, 1)
        XCTAssertEqual(session.starts, 1)
        XCTAssertGreaterThan(clock.pendingCount, 0, "an adopted first start must arm the progress watch")
        XCTAssertNotNil(handler.configChangeObserver)
        handler.stop()
        XCTAssertEqual(session.teardowns, 1)
    }

    /// The deadline and the return cross: the wait gives up in the same
    /// instant the start reports back. The start returned, so it is adopted
    /// rather than thrown away with a working engine behind it.
    func testAFirstStartThatReturnsAsTheDeadlinePassesIsAdopted() throws {
        let session = FirstStartSession()
        let (handler, _) = makeHandler(session) { done, _ in
            done.wait()
            return false
        }

        try handler.start()

        XCTAssertTrue(handler.isRecording)
        XCTAssertNotNil(session.tapBlock)
        handler.stop()
    }

    /// The deadline lands after the attempt reported back to the arbiter and
    /// before its outcome is stored. The arbiter says the attempt returned,
    /// so the wait must go on until the attempt's block has ended rather than
    /// read an outcome that is not there yet, and the start is adopted.
    func testADeadlineJustAfterTheReportWaitsForTheOutcome() throws {
        let session = FirstStartSession()
        let reported = DispatchSemaphore(value: 0)
        let (handler, _) = makeHandler(session) { _, _ in
            reported.wait()
            return false
        }
        handler.startSeams.afterFirstStartReport = {
            reported.signal()
            // Long enough for the main thread to read too early, if it does.
            Thread.sleep(forTimeInterval: 0.3)
        }

        try handler.start()

        XCTAssertTrue(handler.isRecording, "a start that returned must be adopted")
        handler.stop()
    }

    /// The wait after a report is bounded too: should the rest of the block
    /// ever block, the start gives up rather than freeze the main thread.
    ///
    /// It is a short grace, not a second deadline: the rest of the block does
    /// not block, so the main thread's whole wait stays the deadline plus
    /// that grace. Measured from the moment the first wait gave up, which
    /// here is at once.
    func testTheWaitAfterAReportIsBounded() throws {
        let session = FirstStartSession()
        let reported = DispatchSemaphore(value: 0)
        let unpark = DispatchSemaphore(value: 0)
        let gaveUpAt = OSAllocatedUnfairLock<Date?>(initialState: nil)
        let (handler, _) = makeHandler(session) { _, _ in
            reported.wait()
            gaveUpAt.withLock { $0 = Date() }
            return false
        }
        handler.startSeams.afterFirstStartReport = {
            reported.signal()
            _ = unpark.wait(timeout: .now() + 12)
        }
        defer { unpark.signal() }

        XCTAssertThrowsError(try handler.start())
        let gaveUp = try XCTUnwrap(gaveUpAt.withLock { $0 })
        let waited = Date().timeIntervalSince(gaveUp)
        XCTAssertGreaterThanOrEqual(waited, MicCaptureHandler.firstStartReportGrace - 0.05)
        XCTAssertLessThan(waited, MicCaptureHandler.firstStartReportGrace + 0.25)
        XCTAssertLessThan(MicCaptureHandler.firstStartReportGrace, 1, "a grace, not a second deadline")
    }

    /// The deadline passed and the recording went on without the
    /// microphone, with no stop: a restart that misses its deadline ends the
    /// same way, and the recording runs on with the app tap. When the call
    /// returns, the attempt is no longer current and must not open the input
    /// under that recording (issue #693). Every other late-return test stops
    /// the capture first, which a check for "stopped" alone would pass.
    func testAFirstStartGivenUpWithoutAStopDoesNotOpenTheInputWhenItReturns() throws {
        let session = FirstStartSession()
        session.shouldWedge = true
        let (handler, _) = makeHandler(session, giveUpOnceWedged: true)

        XCTAssertThrowsError(try handler.start())
        session.release()
        handler.restartQueue.sync {}

        XCTAssertNil(session.tapBlock, "a late return must not install a tap")
        XCTAssertEqual(session.starts, 0, "a late return must not open the input")
    }

    /// The attempt's block only began after the deadline had passed: the
    /// restart queue was busy until then. It must not enter the engine at
    /// all, since reading the hardware format is where the issue #588 loop
    /// lives, for an attempt nobody wants any more.
    func testAFirstStartWhoseBlockBeginsAfterTheDeadlineDoesNotEnterTheEngine() throws {
        let session = FirstStartSession()
        let (handler, _) = makeHandler(session) { _, _ in false }
        let queueFree = DispatchSemaphore(value: 0)
        handler.restartQueue.async { _ = queueFree.wait(timeout: .now() + 5) }

        XCTAssertThrowsError(try handler.start())
        queueFree.signal()
        handler.restartQueue.sync {}

        XCTAssertEqual(session.engineCallsOffMain + session.engineCallsOnMain, 0, "the given-up attempt must not read the format")
        XCTAssertEqual(session.teardowns, 1, "and still releases its engine")
    }

    /// A file that was at the path before the start is not the late start's
    /// to remove: it was given up before it could create one. The capture
    /// session leaves such a file alone for the same reason.
    func testALateFirstStartLeavesAFileItDidNotCreateAlone() throws {
        let session = FirstStartSession()
        session.shouldWedge = true
        let (handler, url) = makeHandler(session, giveUpOnceWedged: true)
        let existing = Data(repeating: 7, count: 18)
        try existing.write(to: url)

        XCTAssertThrowsError(try handler.start())
        handler.stop()
        session.release()
        handler.restartQueue.sync {}

        XCTAssertEqual(try? Data(contentsOf: url), existing)
    }

    /// The attempt was allowed to create the recording's file, and then the
    /// deadline passed and the capture was stopped before it did. The file it
    /// creates afterwards belongs to no recording; nothing else would ever
    /// remove it, so the attempt does.
    func testAFileCreatedAfterTheDeadlineIsRemovedByTheLateAttempt() throws {
        let session = FirstStartSession()
        let parked = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let (handler, url) = makeHandler(session) { _, _ in
            parked.wait()
            return false
        }
        handler.startSeams.beforeOutputFile = {
            parked.signal()
            _ = proceed.wait(timeout: .now() + 5)
        }

        XCTAssertThrowsError(try handler.start())
        handler.stop()
        proceed.signal()
        handler.restartQueue.sync {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the late attempt must remove the file it created")
        XCTAssertNil(handler.outputFile, "nor keep it open")
        XCTAssertEqual(session.starts, 0, "and must not open the input")
    }

    /// A start that comes back with an error is thrown as that error, as
    /// before, and the stop that follows releases the engine.
    func testAFailedFirstStartThrowsItsOwnError() throws {
        let session = FirstStartSession()
        session.shouldThrow = true
        let (handler, _) = makeHandler(session)

        XCTAssertThrowsError(try handler.start()) { error in
            guard case .noInputDevice = error as? MicCaptureError else {
                return XCTFail("expected the start's own error, got \(error)")
            }
        }
        XCTAssertFalse(handler.isRecording)
        handler.stop()
        XCTAssertEqual(session.teardowns, 1, "nothing holds a failed start's engine, so a stop releases it")
    }
}
