@testable import AudioTapLib
import XCTest

/// The app-audio tap has the same hole the microphone path had (issue #588):
/// `OutputDeviceChangeCoordinator` bounds how many restart attempts are made, not
/// how long one may take, and the attempt ran on the main queue. In the incident
/// that cost the entire remote track for three hours, because the tap teardown
/// had already happened and its rebuild sat behind the wedged main thread while
/// the built-in speakers were healthy the whole time.
@available(macOS 14.2, *)
final class AppAudioCaptureWedgeTests: XCTestCase {
    /// Stands in for the HAL calls `startCapture` makes, with the same shape the
    /// real wedge has: while blocked it holds a lock every other operation also
    /// takes, so a give-up path that still tears resources down deadlocks the
    /// test instead of passing it.
    private final class Attempt {
        private let halLock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private let countLock = NSLock()
        private var _starts = 0

        var shouldWedge = false
        /// When true, the attempt THROWS instead, so the coordinator's retry
        /// budget is what runs out rather than a deadline.
        var shouldFail = false
        let entered = XCTestExpectation(description: "attempt entered the wedging call")

        var starts: Int {
            countLock.lock(); defer { countLock.unlock() }
            return _starts
        }

        func release() {
            gate.signal()
        }

        func run() throws {
            countLock.lock(); _starts += 1; countLock.unlock()
            if shouldFail { throw MicCaptureError.noInputDevice }
            guard shouldWedge else { return }
            halLock.lock()
            defer { halLock.unlock() }
            entered.fulfill()
            gate.wait()
        }

        /// What a teardown would do: taking the same lock the wedged call holds.
        func teardown() {
            halLock.lock()
            halLock.unlock()
        }
    }

    private func makeCapture(_ attempt: Attempt) -> AppAudioCapture {
        AppAudioCapture(pids: [1], outputFileDescriptor: FileHandle.nullDevice.fileDescriptor) {
            try attempt.run()
            // These tests are about the restart choreography, not about what an
            // attempt builds; returning nothing keeps their dynamics unchanged.
            return nil
        }
    }

    func testAWedgedRestartDoesNotBlockTheMainThread() throws {
        let attempt = Attempt()
        let capture = makeCapture(attempt)
        defer { attempt.release() }

        try capture.start()
        attempt.shouldWedge = true
        capture.handleOutputDeviceChanged()
        wait(for: [attempt.entered], timeout: 5)

        let mainIsAlive = expectation(description: "main queue still services work")
        DispatchQueue.main.async { mainIsAlive.fulfill() }
        wait(for: [mainIsAlive], timeout: 2)
    }

    func testAWedgedRestartGivesUpWithinTheDeadline() throws {
        let attempt = Attempt()
        let capture = makeCapture(attempt)
        defer { attempt.release() }

        let gaveUp = expectation(description: "give-up reported")
        capture.onGiveUp = { gaveUp.fulfill() }

        try capture.start()
        attempt.shouldWedge = true
        capture.handleOutputDeviceChanged()

        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)
    }

    func testNoFurtherAttemptRunsAfterAGiveUp() throws {
        let attempt = Attempt()
        let capture = makeCapture(attempt)
        defer { attempt.release() }

        let gaveUp = expectation(description: "give-up reported")
        capture.onGiveUp = { gaveUp.fulfill() }

        try capture.start()
        attempt.shouldWedge = true
        capture.handleOutputDeviceChanged()
        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)

        let startsAtGiveUp = attempt.starts
        // Another device change while the old attempt is still stuck must not
        // start a second one: each wedged attempt leaks a thread.
        capture.handleOutputDeviceChanged()
        let settled = expectation(description: "any retry would have run by now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(attempt.starts, startsAtGiveUp)
    }

    func testAScheduledRetryDoesNotResurrectCaptureAfterAStop() throws {
        // No wedge needed for this one. A device change schedules a retry, the
        // user stops the recording before it fires, and the retry used to run
        // anyway and bring capture back up against a file descriptor the session
        // had already closed. Removing a headset as the meeting ends is exactly
        // this timing.
        let attempt = Attempt()
        let capture = makeCapture(attempt)
        // Typed local, not a trailing closure: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call. One fast
        // retry then give up, because these tests are about the wedge and the
        // give-up, not about how patient the production budget is.
        let fastRetry: @Sendable (Int) -> CaptureRestartRetryAction = { attemptsSoFar in
            attemptsSoFar < 1 ? .retry(afterSeconds: 0.05) : .giveUp
        }
        capture.deviceChangeCoordinator = OutputDeviceChangeCoordinator(
            initialRestartDelay: 0.05, decideRetry: fastRetry,
        )

        try capture.start()
        let startsAfterStart = attempt.starts

        capture.handleOutputDeviceChanged()
        capture.stop()

        let settled = expectation(description: "the scheduled retry would have fired by now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(attempt.starts, startsAfterStart, "a stopped session must not restart capture")
    }

    func testAnExhaustedRetryBudgetIsAGiveUpHereToo() throws {
        // The other way the app track dies: attempts that RETURN with an error
        // until the coordinator's budget runs out. The microphone path treats
        // that as a full give-up, and the channel-health message the user sees
        // depends on it, so the two channels must agree.
        let attempt = Attempt()
        let capture = makeCapture(attempt)
        // Typed local, not a trailing closure: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call. One fast
        // retry then give up, because these tests are about the wedge and the
        // give-up, not about how patient the production budget is.
        let fastRetry: @Sendable (Int) -> CaptureRestartRetryAction = { attemptsSoFar in
            attemptsSoFar < 1 ? .retry(afterSeconds: 0.05) : .giveUp
        }
        capture.deviceChangeCoordinator = OutputDeviceChangeCoordinator(
            initialRestartDelay: 0.05, decideRetry: fastRetry,
        )

        let gaveUp = expectation(description: "give-up reported")
        capture.onGiveUp = { gaveUp.fulfill() }

        try capture.start()
        attempt.shouldFail = true
        capture.handleOutputDeviceChanged()

        wait(for: [gaveUp], timeout: 10)
    }
}
