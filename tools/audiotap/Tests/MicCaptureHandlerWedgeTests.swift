@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// What happens when a restart attempt never returns (issue #588).
///
/// The fake below deliberately mirrors the real failure's shape in one respect
/// that a naive fake would miss: the wedged AVFAudio call holds the engine's
/// internal mutex, so every other engine operation blocks behind it. A fake that
/// merely sleeps would let a give-up path that still calls `teardown()` pass the
/// test while the real app freezes solid. So the blocking operation here holds a
/// lock that every other method also takes, and the test asserts on the recorded
/// calls rather than on timing.
final class MicCaptureHandlerWedgeTests: XCTestCase {
    /// A session whose `hardwareFormat` can be made to block forever while
    /// holding the "engine mutex".
    private final class WedgingSession: MicEngineSessionProviding {
        /// Stands in for AVAudioEngine's internal recursive mutex.
        private let engineMutex = NSLock()
        private let recordLock = NSLock()
        private var _calls: [String] = []
        private let wedge = DispatchSemaphore(value: 0)

        /// When true, `hardwareFormat` blocks until `release()` is called.
        var shouldWedge = false
        /// When true, `hardwareFormat` throws instead, so the attempt RETURNS with
        /// an error and the retry budget is what runs out.
        var shouldFail = false
        /// Set once the wedged call has actually entered and taken the mutex.
        let entered = XCTestExpectation(description: "attempt entered the wedging call")

        var calls: [String] {
            recordLock.lock(); defer { recordLock.unlock() }
            return _calls
        }

        private func record(_ s: String) {
            recordLock.lock(); _calls.append(s); recordLock.unlock()
        }

        let notificationObject: AnyObject = NSObject()
        // swiftlint:disable:next force_unwrapping
        var format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

        func release() {
            wedge.signal()
        }

        func hardwareFormat(deviceUID _: String?) throws -> AVAudioFormat {
            record("hardwareFormat")
            if shouldFail { throw MicCaptureError.noInputDevice }
            if shouldWedge {
                engineMutex.lock()
                defer { engineMutex.unlock() }
                entered.fulfill()
                wedge.wait()
            }
            return format
        }

        /// The handler's real tap block, so a test can drive actual audio through
        /// the production write path instead of leaving the WAV header-only.
        var tapBlock: AVAudioNodeTapBlock?

        func installTap(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
            engineMutex.lock(); defer { engineMutex.unlock() }
            record("installTap(\(Int(format.sampleRate)))")
            tapBlock = block
        }

        func start() {
            engineMutex.lock(); defer { engineMutex.unlock() }
            record("start")
        }

        func teardown() {
            // Taking the same mutex is the point: if a give-up path calls this
            // while an attempt is wedged, the test deadlocks instead of passing.
            engineMutex.lock(); defer { engineMutex.unlock() }
            record("teardown")
        }
    }

    /// One buffer of non-silent audio in the session's format.
    private func makeBuffer(_ format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        buffer.frameLength = 4096
        for channel in 0 ..< Int(format.channelCount) {
            let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0 ..< 4096 {
                samples[frame] = Float(sin(Double(frame) * 0.05)) * 0.5
            }
        }
        return buffer
    }

    private func makeHandler(
        sessions: [WedgingSession],
    ) -> (MicCaptureHandler, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wedge-\(UUID().uuidString).wav")
        var remaining = sessions
        let handler = MicCaptureHandler(outputURL: url) {
            remaining.isEmpty ? WedgingSession() : remaining.removeFirst()
        }
        return (handler, url)
    }

    // MARK: -

    func testAWedgedAttemptDoesNotBlockTheMainThread() throws {
        // The whole point of the fix: one stuck CoreAudio call must cost the
        // microphone track, not the application.
        let first = WedgingSession()
        let wedging = WedgingSession()
        wedging.shouldWedge = true
        let (handler, url) = makeHandler(sessions: [first, wedging])
        defer { try? FileManager.default.removeItem(at: url); wedging.release() }

        try handler.start()
        handler.handleDeviceChange()
        wait(for: [wedging.entered], timeout: 5)

        let mainIsAlive = expectation(description: "main queue still services work")
        DispatchQueue.main.async { mainIsAlive.fulfill() }
        wait(for: [mainIsAlive], timeout: 2)
    }

    func testAWedgedAttemptGivesUpWithinTheDeadline() throws {
        let first = WedgingSession()
        let wedging = WedgingSession()
        wedging.shouldWedge = true
        let (handler, url) = makeHandler(sessions: [first, wedging])
        defer { try? FileManager.default.removeItem(at: url); wedging.release() }

        let gaveUp = expectation(description: "give-up reported")
        handler.onGiveUp = { gaveUp.fulfill() }

        try handler.start()
        handler.handleDeviceChange()

        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)
        // Give-up must never touch the wedged engine: the fake's teardown takes
        // the mutex the wedged call holds, so a call here would hang, but assert
        // it explicitly so the intent is visible.
        XCTAssertFalse(wedging.calls.contains("teardown"))
    }

    func testALateReturningAttemptDoesNotTruncateTheFinishedRecording() throws {
        // The trap this whole design exists for. The give-up closes the WAV.
        // Hours later the wedged call returns, walks on into the code that
        // recreates the output file for writing, and truncates a finished
        // recording to zero bytes.
        let first = WedgingSession()
        let wedging = WedgingSession()
        wedging.shouldWedge = true
        let (handler, url) = makeHandler(sessions: [first, wedging])
        defer { try? FileManager.default.removeItem(at: url) }

        let gaveUp = expectation(description: "give-up reported")
        handler.onGiveUp = { gaveUp.fulfill() }

        try handler.start()

        // Record actual audio through the production tap block, so a truncation
        // is visible in the file rather than hidden behind an empty header.
        let block = try XCTUnwrap(first.tapBlock)
        let buffer = try makeBuffer(first.format)
        for _ in 0 ..< 10 {
            block(buffer, AVAudioTime(hostTime: mach_absolute_time()))
        }

        handler.handleDeviceChange()
        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)

        let afterGiveUp = try Data(contentsOf: url)
        XCTAssertGreaterThan(afterGiveUp.count, 10000, "the recording must contain real audio, not just a header")

        // The wedged call returns and the attempt runs to completion.
        wedging.release()
        let settled = expectation(description: "late attempt settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(
            try Data(contentsOf: url),
            afterGiveUp,
            "the finished recording must be byte-identical after a late return",
        )
    }

    func testATimedOutAttemptSchedulesNoRetry() throws {
        // A restart that FAILS may retry; one that never returns may not, because
        // each wedged attempt leaks a thread burning about a third of a core.
        let first = WedgingSession()
        let wedging = WedgingSession()
        wedging.shouldWedge = true
        let third = WedgingSession()
        let (handler, url) = makeHandler(sessions: [first, wedging, third])
        defer { try? FileManager.default.removeItem(at: url); wedging.release() }

        let gaveUp = expectation(description: "give-up reported")
        handler.onGiveUp = { gaveUp.fulfill() }

        try handler.start()
        handler.handleDeviceChange()
        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)

        let settled = expectation(description: "any retry would have run by now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertTrue(third.calls.isEmpty, "no further attempt may be started after a give-up")
    }

    func testAnExhaustedRetryBudgetEndsTheTrackWithoutLosingIt() throws {
        // The other way to give up: attempts that all RETURN with an error until
        // the budget runs out. End to end, that must report a give-up and leave
        // the recording intact.
        //
        // Honest limitation, established by falsification: this test does NOT
        // pin the sealing itself. Reinstating the old broken seal leaves it
        // green, because the backoff phase already makes `isRecording` false and
        // the restart policy declines on that alone. What pins the seal is
        // `testSealingAfterAReturnedFailureActuallySeals` at the arbiter layer.
        // Both are kept: that one guards the invariant, this one guards the path.
        let first = WedgingSession()
        let failing = (0 ..< 8).map { _ -> WedgingSession in
            let session = WedgingSession()
            session.shouldFail = true
            return session
        }
        let (handler, url) = makeHandler(sessions: [first] + failing)
        defer { try? FileManager.default.removeItem(at: url) }

        let gaveUp = expectation(description: "give-up reported")
        handler.onGiveUp = { gaveUp.fulfill() }

        try handler.start()
        let block = try XCTUnwrap(first.tapBlock)
        let buffer = try makeBuffer(first.format)
        for _ in 0 ..< 10 {
            block(buffer, AVAudioTime(hostTime: mach_absolute_time()))
        }

        handler.handleDeviceChange()
        // The backoff schedule sums to a few seconds across the whole budget.
        wait(for: [gaveUp], timeout: 30)

        let afterGiveUp = try Data(contentsOf: url)
        XCTAssertGreaterThan(afterGiveUp.count, 10000, "the recording must contain real audio")

        // The flapping device supplies one more event.
        handler.handleDeviceChange()
        let settled = expectation(description: "any relaunch would have run by now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(
            try Data(contentsOf: url),
            afterGiveUp,
            "a sealed session must not recreate and truncate the recording",
        )
    }

    // MARK: - Publication

    /// Drain the main queue until `condition` holds. Adoption is dispatched to the
    /// main queue from the restart queue, so there is no expectation the fake can
    /// fulfil at the right moment: the observable is the handler's own state after
    /// that block ran.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool,
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    func testASuccessfulAttemptBecomesTheLiveSession() throws {
        // The happy half of the publication rule, which the wedge tests above can
        // never reach: their fake never returns, so nothing is ever adopted.
        let first = WedgingSession()
        let candidate = WedgingSession()
        let (handler, url) = makeHandler(sessions: [first, candidate])
        defer { try? FileManager.default.removeItem(at: url) }

        try handler.start()
        XCTAssertIdentical(handler.session as AnyObject, first, "start() must install the first session")

        handler.handleDeviceChange()
        waitUntil("the successful attempt became the live session") {
            (handler.session as AnyObject) === candidate
        }

        XCTAssertFalse(
            candidate.calls.contains("teardown"),
            "an adopted session must not also be torn down — it is the live one now",
        )
        XCTAssertTrue(
            first.calls.contains("teardown"),
            "the outgoing session must be released, or every device change leaks an engine",
        )
    }

    func testAnAttemptThatSucceedsAfterAStopIsDiscarded() throws {
        // The rule the whole arbiter exists for, asserted on the handler rather
        // than on the state machine: a restart that comes back after the session
        // was sealed must publish nothing. `RestartArbiterTests` pins the decision
        // (commitReady on a sealed session is rejectStale); this pins the reaction.
        let first = WedgingSession()
        let candidate = WedgingSession()
        candidate.shouldWedge = true
        let (handler, url) = makeHandler(sessions: [first, candidate])
        defer { try? FileManager.default.removeItem(at: url) }

        try handler.start()
        handler.handleDeviceChange()
        wait(for: [candidate.entered], timeout: 5)

        // Sealing while the attempt sits inside the engine must not block here:
        // that is the .sealAndSkipEngine branch, which deliberately leaves the
        // engine the attempt is stuck in alone.
        handler.stop()
        candidate.release()

        waitUntil("the late attempt tore its own work down") {
            candidate.calls.contains("teardown")
        }
        XCTAssertNotIdentical(
            handler.session as AnyObject, candidate,
            "a restart that finished after the stop must never become the live session",
        )
    }
}
