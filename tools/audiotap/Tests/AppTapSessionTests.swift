@testable import AudioTapLib
import CoreAudio
import XCTest

/// The HAL objects one capture attempt builds, as a value that owns them.
///
/// None of this is reachable by a test today: `startCapture` writes the ids into
/// shared fields as it goes, and the test seam replaces the whole function, so
/// the release choreography is verified by reading. Giving the attempt an object
/// to own is what makes the choreography assertable without audio hardware, and
/// these are the assertions it buys.
@available(macOS 14.2, *)
final class AppTapSessionTests: XCTestCase {
    /// Records what the session asks the HAL to do, in order. Unchecked because
    /// the HAL closures are `@Sendable`; the lock is what actually makes it safe,
    /// and the session calls them one at a time anyway.
    private final class HALSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []

        var calls: [String] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        private func record(_ s: String) {
            lock.lock(); _calls.append(s); lock.unlock()
        }

        func operations() -> AppTapSessionHAL {
            AppTapSessionHAL(
                stopDevice: { [weak self] device, _ in self?.record("stop(\(device))") },
                destroyIOProc: { [weak self] device, _ in self?.record("destroyIOProc(\(device))") },
                destroyAggregate: { [weak self] device in self?.record("destroyAggregate(\(device))") },
                destroyTap: { [weak self] tap in self?.record("destroyTap(\(tap))") },
            )
        }

        func recordDrain() {
            record("drain")
        }
    }

    private func makeSession(
        spy: HALSpy, withIOProc: Bool = true,
    ) -> AppTapSession {
        let session = AppTapSession(tapID: 11, hal: spy.operations()) { spy.recordDrain() }
        session.attach(aggregateID: 22, resolvedSampleRate: 48000)
        if withIOProc {
            // A captureless closure converts to the C function pointer the HAL
            // hands back. It is never invoked here; the session only stores it.
            let proc: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }
            session.attach(procID: proc)
        }
        return session
    }

    func testDestroyReleasesInTheOrderTheHalRequires() {
        let spy = HALSpy()
        let session = makeSession(spy: spy)

        session.destroy()

        // The drain must sit between destroying the IOProc and destroying the
        // device: a block already dispatched onto the write queue would
        // otherwise write to a file descriptor the caller is about to close.
        XCTAssertEqual(
            spy.calls,
            ["stop(22)", "destroyIOProc(22)", "drain", "destroyAggregate(22)", "destroyTap(11)"],
        )
    }

    func testDestroyIsSingleShot() {
        let spy = HALSpy()
        let session = makeSession(spy: spy)

        session.destroy()
        session.destroy()
        session.destroy()

        // Ownership, not flags, is what should make this safe: whoever holds the
        // session destroys it once. The guard exists so a stale attempt racing an
        // adoption cannot free ids the HAL may already have recycled.
        XCTAssertEqual(spy.calls.count { $0.hasPrefix("destroyTap") }, 1)
        XCTAssertEqual(spy.calls.count { $0.hasPrefix("destroyAggregate") }, 1)
        XCTAssertEqual(spy.calls.count { $0.hasPrefix("destroyIOProc") }, 1)
    }

    func testASessionThatNeverRegisteredAnIOProcStillReleasesTheRest() {
        let spy = HALSpy()
        let session = makeSession(spy: spy, withIOProc: false)

        session.destroy()

        // This is the aggregate-creation and IOProc-creation failure paths: the
        // attempt threw before it had a registration, and must still hand back
        // the tap and the aggregate rather than leaking them.
        XCTAssertEqual(spy.calls, ["drain", "destroyAggregate(22)", "destroyTap(11)"])
    }

    func testItDoesNotAskTheHalToDestroyIdsItNeverGot() {
        let spy = HALSpy()
        // The aggregate-creation failure path: the attempt owns a tap and nothing
        // else. Handing kAudioObjectUnknown to CoreAudio is not something this
        // code should rely on being harmless, so those calls are skipped.
        // No `attach`: the aggregate never came into existence.
        let session = AppTapSession(tapID: 11, hal: spy.operations()) { spy.recordDrain() }

        session.destroy()

        XCTAssertEqual(spy.calls, ["drain", "destroyTap(11)"])
    }

    func testAnUnusedSessionReportsWhatItOwns() {
        let spy = HALSpy()
        let session = makeSession(spy: spy, withIOProc: false)

        XCTAssertEqual(session.tapID, 11)
        XCTAssertEqual(session.aggregateID, 22)
        XCTAssertEqual(session.resolvedSampleRate, 48000)
        XCTAssertNil(session.procID, "a session only has a registration once one was attached")
    }
}
