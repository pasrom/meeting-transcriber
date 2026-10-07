@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The fixture both watchdog suites share: a handler on a scripted engine,
/// driven through its real restart path with a manual clock, and what it
/// reported. A plain object rather than a test-case base class, so each suite
/// holds a fresh one per test. Everything below the engine is faked; what is real is the
/// handler, the arbiter, the restart queue and the notification wiring.
/// Sessions deliver through the handler's own tap block, and stop delivering
/// once torn down.
@MainActor
final class MicWatchdogHarness {
    let factory = ScriptedSessionFactory()
    let clock = ManualMainClock()
    private(set) var stalls: [TimeInterval] = []
    /// What each stall said about itself, in order.
    private(set) var stallDetails: [MicStallDetails] = []
    private(set) var resumes = 0
    private(set) var gaveUp = 0
    private(set) var started: TimeInterval = 0
    private(set) var url: URL?

    var sessions: [ScriptedMicSession] {
        factory.sessions
    }

    /// Unblocks any wedged session and removes the file. Call from the
    /// suite's `tearDown`.
    func tearDown() {
        for session in sessions {
            session.release()
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func makeHandler(
        debugFault: DebugTapFault? = nil,
        beforeBridgeChunk: @escaping @Sendable () -> Void = {},
    ) throws -> MicCaptureHandler {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-\(UUID().uuidString).wav")
        self.url = url
        let factory = factory
        // Typed locals, not trailing closures: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
        let makeSession: () -> any MicEngineSessionProviding = { factory.make() }
        let handler = MicCaptureHandler(
            outputURL: url, debugFault: debugFault, sessionFactory: makeSession,
            scheduleOnMain: clock.scheduler, clock: clock.reading,
        )
        handler.bridgeGate.beforeChunk = beforeBridgeChunk
        handler.onStall = { [weak self] details in
            guard let self else { return }
            stalls.append(clock.now - started)
            stallDetails.append(details)
        }
        handler.onResume = { [weak self] in self?.resumes += 1 }
        handler.onGiveUp = { [weak self] in self?.gaveUp += 1 }
        started = clock.now
        try handler.start()
        return handler
    }

    /// A mach host time `seconds` ago, for a buffer stamped in the past. The
    /// mach clock counts from boot, so on a machine up for less than that,
    /// a freshly started CI runner say, the subtraction would underflow and
    /// trap the whole test process; the test is skipped instead.
    func hostTime(secondsAgo seconds: TimeInterval) throws -> UInt64 {
        let now = mach_absolute_time()
        let back = ticks(seconds)
        guard back < now else {
            throw XCTSkip("this machine has been up for less than \(Int(seconds)) s, the time this test stamps a buffer in the past")
        }
        return now - back
    }

    /// Mach ticks for a span of seconds.
    func ticks(_ seconds: TimeInterval) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return UInt64(seconds * 1e9) * UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    func postConfigChange(_ handler: MicCaptureHandler) {
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: handler.session.notificationObject,
        )
    }

    /// Deliver a buffer on `session` every `interval` seconds, starting after
    /// `delay`, until it is torn down or `until` (relative to the start) is
    /// reached.
    func keepDelivering(
        _ session: ScriptedMicSession,
        after delay: TimeInterval = 0,
        every interval: TimeInterval = 0.5,
        until: TimeInterval = .infinity,
    ) {
        let clock = clock
        let started = started
        let tick = DeliveryLoop(session: session, clock: clock, interval: interval, until: started + until)
        clock.scheduler(delay) { tick.fire() }
    }
}

@MainActor
extension XCTestCase {
    /// A configuration change every 200 ms on whichever engine is current,
    /// which is the field rate. A change posted while an attempt is out lands
    /// on no observer, as in production. Bounded by the clock and a hard cap,
    /// so a capture that stops restarting ends the driver.
    func runStorm(
        _ handler: MicCaptureHandler,
        on harness: MicWatchdogHarness,
        restarts: Int = .max,
        seconds: TimeInterval = .infinity,
    ) {
        let end = min(harness.clock.now + seconds, harness.clock.now + 3600)
        let first = harness.sessions.count
        while harness.clock.now < end {
            harness.clock.advance(by: 0.2) { settle(handler) }
            guard harness.sessions.count - first < restarts else { return }
            harness.postConfigChange(handler)
            settle(handler)
        }
    }
}

/// Delivers on one session at a fixed interval on the manual clock, until the
/// session is torn down or the end time passes.
final class DeliveryLoop: @unchecked Sendable {
    let session: ScriptedMicSession
    let clock: ManualMainClock
    let interval: TimeInterval
    let until: TimeInterval

    init(session: ScriptedMicSession, clock: ManualMainClock, interval: TimeInterval, until: TimeInterval) {
        self.session = session
        self.clock = clock
        self.interval = interval
        self.until = until
    }

    func fire() {
        guard session.teardowns == 0, clock.now < until else { return }
        session.deliver()
        clock.scheduler(interval) { self.fire() }
    }
}
