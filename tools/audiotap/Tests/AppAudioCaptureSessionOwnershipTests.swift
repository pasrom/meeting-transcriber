@testable import AudioTapLib
import CoreAudio
import XCTest

/// Who destroys the HAL objects a restart attempt built, and when.
///
/// None of this was assertable before the attempt had an object to own: the ids
/// went into fields as the attempt progressed, so "the stale attempt cleaned up
/// after itself" and "the stop cleaned up after the stale attempt" were the same
/// observation. Now each attempt hands back a distinguishable session, and the
/// spy records which one was released.
@available(macOS 14.2, *)
final class AppAudioCaptureSessionOwnershipTests: XCTestCase {
    /// Records destroys per session, keyed by the tap id so two attempts in one
    /// test are told apart.
    private final class HALSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _destroyed: [AudioObjectID] = []

        var destroyedTaps: [AudioObjectID] {
            lock.lock(); defer { lock.unlock() }
            return _destroyed
        }

        func operations() -> AppTapSessionHAL {
            AppTapSessionHAL(
                stopDevice: { _, _ in },
                destroyIOProc: { _, _ in },
                destroyAggregate: { _ in },
                destroyTap: { [weak self] tap in
                    self?.lock.lock(); self?._destroyed.append(tap); self?.lock.unlock()
                },
            )
        }
    }

    /// A scripted attempt: hands back a session with the given tap id, and can be
    /// made to block until released so a stop or a deadline lands mid-flight.
    private final class Attempt: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        let entered = XCTestExpectation(description: "attempt is inside the HAL")

        var shouldWedge = false
        var tapIDs: [AudioObjectID] = []
        private let spy: HALSpy
        private let lock = NSLock()
        private var index = 0

        init(spy: HALSpy) {
            self.spy = spy
        }

        func release() {
            gate.signal()
        }

        func run() -> AppTapSession? {
            lock.lock()
            let id = index < tapIDs.count ? tapIDs[index] : AudioObjectID(99)
            index += 1
            lock.unlock()
            if shouldWedge {
                entered.fulfill()
                gate.wait()
            }
            let session = AppTapSession(tapID: id, hal: spy.operations()) {}
            session.attach(aggregateID: id &+ 100, resolvedSampleRate: 48000)
            return session
        }
    }

    private func makeCapture(_ attempt: Attempt) -> AppAudioCapture {
        AppAudioCapture(pids: [1], outputFileDescriptor: FileHandle.nullDevice.fileDescriptor) {
            attempt.run()
        }
    }

    // MARK: -

    func testARestartThatSucceedsAfterAGiveUpDestroysWhatItBuiltAndNothingElse() throws {
        let spy = HALSpy()
        let attempt = Attempt(spy: spy)
        attempt.tapIDs = [1, 2] // 1 is adopted by start(), 2 is the late attempt
        let capture = makeCapture(attempt)

        let gaveUp = expectation(description: "give-up reported")
        capture.onGiveUp = { gaveUp.fulfill() }

        try capture.start()
        attempt.shouldWedge = true
        capture.handleOutputDeviceChanged()
        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)

        // The restart's own stop released the installed session before the
        // attempt launched. The wedged attempt is still holding its own.
        XCTAssertEqual(spy.destroyedTaps, [1])

        attempt.release()
        let settled = expectation(description: "the late attempt has been handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        // It released exactly what it built. Before the attempt owned an object,
        // this path called stopCapture() and freed whatever the fields held.
        XCTAssertEqual(spy.destroyedTaps, [1, 2])

        capture.stop()
        XCTAssertEqual(
            spy.destroyedTaps, [1, 2],
            "a stop must not free a session that was never installed, nor free one twice",
        )
    }

    func testACleanRestartInstallsTheSessionTheAttemptReturned() throws {
        let spy = HALSpy()
        let attempt = Attempt(spy: spy)
        attempt.tapIDs = [1, 2]
        let capture = makeCapture(attempt)

        try capture.start()
        capture.handleOutputDeviceChanged()

        let settled = expectation(description: "the restart completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(spy.destroyedTaps, [1], "the outgoing session is released by the restart")

        capture.stop()
        // The proof of adoption is which session the stop releases: if the
        // restart had failed to install what it built, the stop would free
        // nothing, and a live tap would outlive the recording.
        XCTAssertEqual(spy.destroyedTaps, [1, 2])
    }
}
