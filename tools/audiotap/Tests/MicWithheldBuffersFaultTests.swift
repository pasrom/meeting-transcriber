@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The withheld-buffers fault the mic stall e2e lane injects (issues #724,
/// #706), driven through the handler's real restart path with a manual clock.
///
/// The lane can only prove the watchdog if the fault holds across the
/// watchdog's own remedy: every rebuild brings up a fresh engine, and a fault
/// that lived in one engine would be cured by the first rebuild and the lane
/// would never reach the stall. So every engine here delivers on time, as a
/// real one does, and it is the handler that must drop what they deliver.
@MainActor
final class MicWithheldBuffersFaultTests: XCTestCase {
    private typealias Policy = MicCaptureProgressPolicy

    private var harness = MicWatchdogHarness()

    override func setUp() {
        super.setUp()
        harness = MicWatchdogHarness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    /// Runs `seconds` with every engine the handler builds delivering every
    /// half second from the moment it is built.
    private func runWithEveryEngineDelivering(_ handler: MicCaptureHandler, for seconds: TimeInterval) {
        var seen = 0
        let between = { [self] in
            settle(handler)
            while seen < harness.sessions.count {
                harness.keepDelivering(harness.sessions[seen])
                seen += 1
            }
        }
        between()
        harness.clock.advance(by: seconds, between: between)
    }

    /// The control the other two are read against: the same delivering
    /// engines with no fault are never rebuilt.
    func testWithoutTheFaultDeliveringEnginesAreLeftAlone() throws {
        let handler = try harness.makeHandler()

        runWithEveryEngineDelivering(handler, for: 300)

        XCTAssertEqual(harness.sessions.count, 1)
        XCTAssertEqual(harness.stalls, [])
    }

    /// Withheld from the start: the engine runs and delivers, the handler sees
    /// nothing, and the watchdog rebuilds at 3, 9, 21 and 45 s and releases
    /// the microphone at 60 s, exactly as for an engine that never delivers.
    func testBuffersWithheldFromTheStartAreRebuiltThenStall() throws {
        let handler = try harness.makeHandler(debugFault: .withholdingBuffers(after: 0))

        runWithEveryEngineDelivering(handler, for: 300)

        XCTAssertEqual(harness.sessions.count, 5, "the first engine plus rebuilds at 3, 9, 21 and 45 s")
        XCTAssertEqual(harness.stalls.count, 1)
        let stalledAt = try XCTUnwrap(harness.stalls.first)
        XCTAssertEqual(stalledAt, Policy.maxSecondsWithoutAudio, accuracy: 0.001)
        XCTAssertEqual(harness.gaveUp, 0)
    }

    /// Withheld from ten seconds in: delivered, then stopped with no
    /// configuration change, the shape a one-shot first-buffer check never
    /// sees. Nothing is rebuilt while it delivers; afterwards the budget runs
    /// from the last buffer the watchdog credited, so the stall lands a minute
    /// after the delivery stopped, not a minute after the start.
    func testBuffersWithheldLaterStallAMinuteAfterTheyStopped() throws {
        let handler = try harness.makeHandler(debugFault: .withholdingBuffers(after: 10))

        runWithEveryEngineDelivering(handler, for: 9)
        XCTAssertEqual(harness.sessions.count, 1, "nothing is rebuilt while the buffers still arrive")

        runWithEveryEngineDelivering(handler, for: 300)

        XCTAssertEqual(harness.sessions.count, 5, "rebuilt four times once the buffers stopped")
        XCTAssertEqual(harness.stalls.count, 1)
        let stalledAt = try XCTUnwrap(harness.stalls.first)
        // The last buffer is at 9.5 s; the watchdog notices it at its next
        // check, at most one first deadline later, and credits it there on a
        // manual clock whose mach time does not advance with it.
        XCTAssertGreaterThanOrEqual(stalledAt, 9.5 + Policy.maxSecondsWithoutAudio)
        XCTAssertLessThanOrEqual(stalledAt, 10 + Policy.firstBufferDeadline + Policy.maxSecondsWithoutAudio)
    }
}
