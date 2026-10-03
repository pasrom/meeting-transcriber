@testable import AudioTapLib
import CoreAudio
import XCTest

/// The hardware stand-ins `SilentTrackWatchdogWiringTests` wires a real
/// `AppAudioCapture` to. In their own file only to keep the test class under
/// the length limits; internal rather than private for that reason alone.
@available(macOS 14.2, *)
extension SilentTrackWatchdogWiringTests {
    /// Counts attempts and hands back a session that installs cleanly at a
    /// real rate, so a rebuild completes rather than looping on a rate-zero
    /// "success". The HAL is a no-op: what is asserted is that an attempt ran.
    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var waiters: [(Int, XCTestExpectation)] = []

        var starts: Int {
            lock.withLock { count }
        }

        func expectation(reaching target: Int) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: "attempt \(target) ran")
            lock.withLock {
                if count >= target { expectation.fulfill() } else { waiters.append((target, expectation)) }
            }
            return expectation
        }

        /// When set, every attempt from now on throws, so a restart runs
        /// out of retries and gives up.
        var fail: Bool {
            get { lock.withLock { failing } }
            set { lock.withLock { failing = newValue } }
        }

        private var failing = false

        /// When set, every attempt from now on blocks until `release` is
        /// signalled: an attempt stuck inside coreaudiod (issue #588), which
        /// only the restart deadline ends.
        var hang: Bool {
            get { lock.withLock { hanging } }
            set { lock.withLock { hanging = newValue } }
        }

        private var hanging = false
        let release = DispatchSemaphore(value: 0)

        func run() throws -> AppTapSession? {
            let (fails, hangs) = lock.withLock {
                count += 1
                waiters.removeAll { target, expectation in
                    guard count >= target else { return false }
                    expectation.fulfill()
                    return true
                }
                return (failing, hanging)
            }
            if hangs { release.wait() }
            if fails { throw MicCaptureError.noInputDevice }
            return Self.session(tapID: 7)
        }

        static func session(tapID: AudioObjectID) -> AppTapSession {
            let hal = AppTapSessionHAL(
                stopDevice: { _, _ in }, destroyIOProc: { _, _ in },
                destroyAggregate: { _ in }, destroyTap: { _ in },
            )
            let session = AppTapSession(tapID: tapID, hal: hal) {}
            session.attach(aggregateID: tapID &+ 1, resolvedSampleRate: 48000)
            return session
        }
    }

    /// Stands in for the HAL read: every tapped process reports the given
    /// `IsRunningOutput`. Can be held, which is how a probe still in flight
    /// when the recording stops is reproduced.
    final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var _running = true
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var hold = false

        var running: Bool {
            get { lock.withLock { _running } }
            set { lock.withLock { _running = newValue } }
        }

        var readCount: Int {
            lock.withLock { reads }
        }

        var probe: SilentTrackDiagnostics.Probe {
            { [self] processes, _ in
                let running = lock.withLock { () -> Bool in
                    reads += 1
                    return _running
                }
                if hold {
                    entered.signal()
                    release.wait()
                }
                return SilentTrackDiagnostics.ProbeSnapshot(
                    processes: processes.map { process in
                        ProcessOutputState(process: process, isRunningOutput: .value(running), outputDevices: .value([8]))
                    },
                    device: nil,
                )
            }
        }
    }

    /// The watchdog's clock, set by the test and counted when read.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1000
        private var readCount = 0

        var now: TimeInterval {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }

        var reads: Int {
            lock.withLock { readCount }
        }

        func read() -> TimeInterval {
            lock.withLock {
                readCount += 1
                return value
            }
        }
    }
}
