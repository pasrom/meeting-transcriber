@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// A microphone engine session that never touches audio hardware, scripted per
/// test: it can throw on start, wedge inside the call that brings the engine
/// up, and deliver buffers only when told.
final class ScriptedMicSession: MicEngineSessionProviding, @unchecked Sendable {
    // swiftlint:disable:next force_unwrapping
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private let object = NSObject()
    private let lock = NSLock()

    /// `hardwareFormat` throws, so the attempt returns with an error.
    var shouldThrow = false
    /// `hardwareFormat` blocks until `release()`, holding the engine mutex
    /// that `teardown` also takes, as the real wedge in issue #588 does.
    var shouldWedge = false
    /// With `shouldWedge`: once released, throw instead of coming up, as an
    /// attempt does that spends seconds inside the engine and then fails.
    var throwAfterRelease = false
    /// Deliver one buffer the first time the handler reads the notification
    /// object, which it does right after adopting this session and before it
    /// judges the epoch that adoption ended.
    var deliverOnObserverInstall = false

    let entered = XCTestExpectation(description: "attempt entered the wedging call")
    private let wedge = DispatchSemaphore(value: 0)
    private let engineMutex = NSLock()
    private var storedTapBlock: AVAudioNodeTapBlock?
    private var storedTeardowns = 0

    var teardowns: Int {
        lock.withLock { storedTeardowns }
    }

    var notificationObject: AnyObject {
        if deliverOnObserverInstall {
            deliverOnObserverInstall = false
            deliver()
        }
        return object
    }

    func hardwareFormat(deviceUID _: String?) throws -> AVAudioFormat {
        if shouldThrow { throw MicCaptureError.noInputDevice }
        if shouldWedge {
            engineMutex.lock()
            defer { engineMutex.unlock() }
            entered.fulfill()
            wedge.wait()
            if throwAfterRelease { throw MicCaptureError.noInputDevice }
        }
        return format
    }

    func installTap(format _: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        lock.withLock { storedTapBlock = block }
    }

    func start() {}

    func teardown() {
        engineMutex.lock()
        defer { engineMutex.unlock() }
        lock.withLock {
            storedTeardowns += 1
            storedTapBlock = nil
        }
    }

    func release() {
        wedge.signal()
    }

    /// One buffer through the handler's real tap block. A released engine
    /// delivers nothing, as a real one does.
    func deliver(hostTime: UInt64 = mach_absolute_time()) {
        guard let block = lock.withLock({ storedTapBlock }),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480) else { return }
        buffer.frameLength = 480
        block(buffer, AVAudioTime(hostTime: hostTime))
    }
}

/// The sessions a handler built, in order, and how each later one is to
/// behave. Locked because restart attempts build their session on the restart
/// queue while the test reads from main.
final class ScriptedSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var built: [ScriptedMicSession] = []
    private var script: [@Sendable (ScriptedMicSession) -> Void] = []

    /// Configure the sessions built after the first, in order; any beyond the
    /// script behave normally.
    func script(_ steps: [@Sendable (ScriptedMicSession) -> Void]) {
        lock.withLock { script = steps }
    }

    var sessions: [ScriptedMicSession] {
        lock.withLock { built }
    }

    func make() -> ScriptedMicSession {
        let session = ScriptedMicSession()
        lock.withLock {
            if !built.isEmpty, !script.isEmpty {
                script.removeFirst()(session)
            }
            built.append(session)
        }
        return session
    }
}

/// Time the restart timers see, and the work they scheduled on it. Driven only
/// from the main queue, which is where the handler schedules.
final class ManualMainClock: @unchecked Sendable {
    private(set) var now: TimeInterval = 1000
    private var jobs: [(due: TimeInterval, work: @Sendable () -> Void)] = []

    var pendingCount: Int {
        jobs.count
    }

    var reading: @Sendable () -> TimeInterval {
        { self.now }
    }

    var scheduler: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void {
        { delay, work in self.jobs.append((self.now + delay, work)) }
    }

    /// More jobs than any scenario here schedules in one advance. A timer that
    /// keeps rescheduling itself without moving the clock (a delay that
    /// rounds to nothing) never lets `advance` return; this turns that hang
    /// into a failure.
    static let maxJobsPerAdvance = 100_000

    /// Move forward, running every job that falls due on the way in order,
    /// including jobs those jobs schedule, and `between` after each.
    func advance(by seconds: TimeInterval, between: () -> Void = {}) {
        let target = now + seconds
        var ran = 0
        while let next = nextDue(by: target) {
            ran += 1
            guard ran <= Self.maxJobsPerAdvance else {
                XCTFail("more than \(Self.maxJobsPerAdvance) timer jobs in one advance at \(now): a timer is rescheduling itself without moving the clock")
                jobs.removeAll()
                return
            }
            let job = jobs.remove(at: next)
            now = max(now, job.due)
            job.work()
            between()
        }
        now = target
    }

    private func nextDue(by target: TimeInterval) -> Int? {
        jobs.indices.filter { jobs[$0].due <= target }.min { jobs[$0].due < jobs[$1].due }
    }
}

extension XCTestCase {
    /// Wait until `factory` has built `count` sessions, for an attempt that is
    /// known to be on its way but cannot be drained because it may wedge.
    func waitForSessions(_ factory: ScriptedSessionFactory, count: Int) {
        let deadline = Date().addingTimeInterval(5)
        while factory.sessions.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertGreaterThanOrEqual(factory.sessions.count, count, "the attempt never built its session")
    }

    /// Let a launched attempt finish on the restart queue and its adoption run
    /// on main. The attempt posts the adoption to main before it returns, so
    /// one main-queue hop after draining the restart queue is behind it. Pass
    /// `drainingRestartQueue: false` while an attempt is wedged there.
    func settle(_ handler: MicCaptureHandler, drainingRestartQueue: Bool = true) {
        if drainingRestartQueue { handler.restartQueue.sync {} }
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }
}
