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

        /// When set, the next attempt succeeds with a session at rate 0,
        /// which the restart path installs and then retries.
        var zeroRateOnce: Bool {
            get { lock.withLock { zeroRate } }
            set { lock.withLock { zeroRate = newValue } }
        }

        private var zeroRate = false

        func run() throws -> AppTapSession? {
            let (fails, hangs, rate) = lock.withLock {
                count += 1
                waiters.removeAll { target, expectation in
                    guard count >= target else { return false }
                    expectation.fulfill()
                    return true
                }
                let rate = zeroRate ? 0 : 48000
                zeroRate = false
                return (failing, hanging, rate)
            }
            if hangs { release.wait() }
            if fails { throw MicCaptureError.noInputDevice }
            return Self.session(tapID: 7, rate: rate)
        }

        static func session(tapID: AudioObjectID, rate: Int = 48000) -> AppTapSession {
            let hal = AppTapSessionHAL(
                stopDevice: { _, _ in }, destroyIOProc: { _, _ in },
                destroyAggregate: { _ in }, destroyTap: { _ in },
            )
            let session = AppTapSession(tapID: tapID, hal: hal) {}
            session.attach(aggregateID: tapID &+ 1, resolvedSampleRate: rate)
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

    /// Holds every deadline the diagnostics arm instead of running it, so a
    /// test fires the one it means, when it means to. Real time would make
    /// "the deadline passed with no buffer" a ten-second sleep.
    final class Deadlines: @unchecked Sendable {
        private let lock = NSLock()
        private var armed: [(offset: TimeInterval, item: DispatchWorkItem)] = []

        var schedule: SilentTrackDiagnostics.DelayedWork {
            { [self] offset, item in lock.withLock { armed.append((offset, item)) } }
        }

        /// The deadlines armed at `offset` that were not cancelled.
        func pending(at offset: TimeInterval) -> [DispatchWorkItem] {
            lock.withLock { armed.filter { $0.offset == offset && !$0.item.isCancelled }.map(\.item) }
        }
    }

    /// One capture with its hardware stand-ins and its clock.
    struct Rig {
        let capture: AppAudioCapture
        let attempts: Attempts
        let state: ProcessState
        let clock: TestClock
        let deadlines: Deadlines

        /// A capture wired to the stand-ins, not yet started. `readAges` is
        /// what the capture reads as the track's live ages; by default the
        /// ages of a run still going.
        static func make(
            watchdog: Bool = true,
            running: Bool = true,
            hold: Bool = false,
            readAges: @escaping @Sendable () -> ChannelSignalAges = { ages(energy: 65) },
            // After `readAges`, so a trailing closure keeps binding to that one.
            sink: @escaping SilentTrackDiagnostics.Sink = { _, _ in },
        ) -> Self {
            let attempts = Attempts()
            let state = ProcessState()
            let clock = TestClock()
            let deadlines = Deadlines()
            state.running = running
            state.hold = hold
            let readClock: @Sendable () -> TimeInterval = { clock.read() }
            return Self(
                capture: AppAudioCapture(
                    pids: [1],
                    outputFileDescriptor: FileHandle.nullDevice.fileDescriptor,
                    attemptBody: { try attempts.run() },
                    silentTrackDiagnostics: SilentTrackDiagnostics(
                        probe: state.probe, sink: sink, delayedWork: deadlines.schedule,
                    ),
                    silentTrackWatchdog: watchdog,
                    signalAgesOverride: readAges,
                    clockOverride: readClock,
                ),
                attempts: attempts,
                state: state,
                clock: clock,
                deadlines: deadlines,
            )
        }
    }
}
