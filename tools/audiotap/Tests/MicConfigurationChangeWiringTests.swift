@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The policy wired into the handler: a configuration change on an engine
/// that is as it started does not build a new one.
@MainActor
final class MicConfigurationChangeWiringTests: XCTestCase {
    private var harness = MicWatchdogHarness()

    override func setUp() {
        super.setUp()
        harness = MicWatchdogHarness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    private let pinned = MicEngineConfiguration(deviceID: 107, sampleRate: 48000, channelCount: 1)

    /// The loop from the field, ended at its first turn: each new engine
    /// raises its own change, and none of them restarts it.
    func testTheChangeAPinnedEngineRaisesItselfDoesNotRestartIt() throws {
        let handler = try harness.makeHandler()
        let first = try XCTUnwrap(harness.sessions.first)
        first.configurationReading = MicConfigurationChangeReading(atStart: pinned, now: pinned, isRunning: true)

        for _ in 0 ..< 5 {
            harness.postConfigChange(handler)
            settle(handler)
        }

        XCTAssertEqual(harness.sessions.count, 1, "no engine was rebuilt for a change it caused itself")
        XCTAssertEqual(first.teardowns, 0)
        XCTAssertTrue(handler.isRecording)
    }

    /// A change that did move the pinned engine still restarts it at once.
    func testARealChangeOnAPinnedEngineStillRestarts() throws {
        let handler = try harness.makeHandler()
        let first = try XCTUnwrap(harness.sessions.first)
        var resampled = pinned
        resampled.sampleRate = 24000
        first.configurationReading = MicConfigurationChangeReading(atStart: pinned, now: resampled, isRunning: true)

        harness.postConfigChange(handler)
        settle(handler)

        XCTAssertEqual(harness.sessions.count, 2, "the format moved, so the engine is rebuilt")
        XCTAssertEqual(first.teardowns, 1)
    }

    /// The net the policy leans on: a pinned engine whose change was ignored
    /// and that then delivers nothing is still rebuilt at its first deadline.
    func testAnIgnoredChangeOnASilentEngineIsStillRebuiltByTheWatchdog() throws {
        let handler = try harness.makeHandler()
        let first = try XCTUnwrap(harness.sessions.first)
        first.configurationReading = MicConfigurationChangeReading(atStart: pinned, now: pinned, isRunning: true)

        harness.postConfigChange(handler)
        settle(handler)
        XCTAssertEqual(harness.sessions.count, 1, "the change itself was ignored")

        harness.clock.advance(by: MicCaptureProgressPolicy.firstBufferDeadline + 0.1) { settle(handler) }

        XCTAssertEqual(harness.sessions.count, 2, "the watchdog rebuilt the engine that delivered nothing")
        XCTAssertEqual(first.teardowns, 1)
    }
}
