@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// A stalled capture brought back by a device change: what brings it back,
/// what bounds it, and how the track stays aligned across the stall.
@MainActor
final class MicCaptureRevivalTests: XCTestCase {
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

    /// The user switches the input or reconnects the headset after being told:
    /// that brings the microphone back, reported once it is running again.
    func testADeviceChangeAfterAStallBringsTheMicrophoneBack() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        XCTAssertEqual(harness.stalls.count, 1)
        let beforeRevival = harness.sessions.count

        handler.handleDeviceChange()
        settle(handler)
        XCTAssertEqual(harness.sessions.count, beforeRevival + 1, "a new engine on the new device")
        XCTAssertTrue(handler.isRecording)
        XCTAssertEqual(harness.resumes, 0, "not resumed until it has delivered")

        try harness.keepDelivering(XCTUnwrap(harness.sessions.last))
        harness.clock.advance(by: 3600) { settle(handler) }
        XCTAssertEqual(harness.resumes, 1, "resumed once it delivered")
        XCTAssertEqual(harness.stalls.count, 1, "and it stays up while it delivers")
    }

    /// Only a change of the input revives: a configuration change reaching a
    /// stalled capture is the storm it was stalled for, not the user acting.
    /// The stall removes the observer that would deliver one, so this guards
    /// the rule rather than a path seen to fire.
    func testAConfigurationChangeDoesNotReviveAStalledCapture() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        XCTAssertEqual(harness.stalls.count, 1)
        let before = harness.sessions.count

        handler.handleDeviceChange(fromConfigurationChange: true)
        settle(handler)

        XCTAssertEqual(harness.sessions.count, before, "no engine started")
        XCTAssertFalse(handler.isRecording)
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .stalled)
    }

    /// The stalled engine was released when it stalled; the revival must not
    /// tear it down a second time.
    func testTheStalledEngineIsReleasedOnceAcrossARevival() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        let stalled = try XCTUnwrap(harness.sessions.last)

        handler.handleDeviceChange()
        settle(handler)

        XCTAssertEqual(stalled.teardowns, 1)
    }

    /// Nor does a retry after the revival's first attempt failed: nothing
    /// adopted a new engine in between, so the one the retry would tear down
    /// is still the one the stall released.
    func testARetriedRevivalDoesNotReleaseTheStalledEngineAgain() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        let stalled = try XCTUnwrap(harness.sessions.last)
        harness.factory.script([{ $0.shouldThrow = true }])

        handler.handleDeviceChange()
        settle(handler)
        harness.clock.advance(by: CaptureRestartRetryPolicy.baseBackoff) { settle(handler) }

        XCTAssertTrue(handler.isRecording, "the retry was adopted")
        XCTAssertEqual(stalled.teardowns, 1)
    }

    /// A revival whose attempts all come back with errors has not wedged
    /// anything: it goes back to stalled, is not reported as lost for good,
    /// and the next device change can try again.
    func testARevivalWhoseAttemptsAllFailReturnsToStalled() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        harness.factory.script(Array(repeating: { $0.shouldThrow = true }, count: CaptureRestartRetryPolicy.maxAttempts + 1))

        handler.handleDeviceChange()
        settle(handler)
        harness.clock.advance(by: 60) { settle(handler) }

        XCTAssertEqual(harness.gaveUp, 0)
        XCTAssertEqual(harness.resumes, 0)
        XCTAssertEqual(harness.stalls.count, 2, "the failed revival is told as a stall again")
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .stalled)
        let before = harness.sessions.count
        handler.handleDeviceChange()
        settle(handler)
        XCTAssertEqual(harness.sessions.count, before + 1)
        XCTAssertTrue(handler.isRecording, "revived on the next device change")
    }

    /// A revival whose attempts keep failing gets the whole budget too, from
    /// the moment it was revived, rather than the retry schedule's count.
    func testARevivalWhoseAttemptsAllFailStallsAtItsBudgetNotAtTheRetryCount() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        harness.factory.script(Array(repeating: { $0.shouldThrow = true }, count: 200))

        handler.handleDeviceChange()
        settle(handler)
        let revivedAt = harness.clock.now - harness.started
        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.stalls.count, 2)
        XCTAssertGreaterThanOrEqual(harness.stalls[1] - revivedAt, Policy.maxSecondsWithoutAudio)
        XCTAssertLessThanOrEqual(
            harness.stalls[1] - revivedAt, Policy.maxSecondsWithoutAudio + CaptureRestartRetryPolicy.maxBackoff,
        )
        XCTAssertEqual(harness.gaveUp, 0)
    }

    /// A default input that keeps flapping must not revive a dead microphone
    /// forever. Revivals that never deliver are capped per stretch without
    /// audio; the one after the cap is ignored and the capture stays released.
    func testRevivalsThatNeverDeliverAreCapped() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        for _ in 0 ..< Policy.maxRevivalsWithoutAudio {
            handler.handleDeviceChange()
            settle(handler)
            harness.clock.advance(by: 120) { settle(handler) }
        }
        XCTAssertEqual(harness.stalls.count, 1 + Policy.maxRevivalsWithoutAudio)
        XCTAssertEqual(
            harness.stallDetails.map(\.mayRevive),
            Array(repeating: true, count: Policy.maxRevivalsWithoutAudio) + [false],
            "only the stall after the last allowed revival says no change of input will help",
        )
        let before = harness.sessions.count

        handler.handleDeviceChange()
        settle(handler)

        XCTAssertEqual(harness.sessions.count, before, "past the cap a device change starts nothing")
        XCTAssertFalse(handler.isRecording)
        XCTAssertEqual(harness.resumes, 0)
    }

    /// Delivery resets the cap: a microphone that came back and later stalls
    /// again gets its revivals afresh.
    func testARevivalThatDeliveredResetsTheCap() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        for _ in 0 ..< Policy.maxRevivalsWithoutAudio - 1 {
            handler.handleDeviceChange()
            settle(handler)
            harness.clock.advance(by: 120) { settle(handler) }
        }
        handler.handleDeviceChange()
        settle(handler)
        try harness.keepDelivering(XCTUnwrap(harness.sessions.last), until: harness.clock.now - harness.started + 5)
        harness.clock.advance(by: 120) { settle(handler) }
        XCTAssertEqual(harness.resumes, 1)

        let before = harness.sessions.count
        handler.handleDeviceChange()
        settle(handler)
        XCTAssertEqual(harness.sessions.count, before + 1, "still allowed after the cap was reset")
    }

    /// Still bounded: a revived capture that stays silent gets a fresh budget
    /// and is released again at its end, not rebuilt forever.
    func testARevivedCaptureThatStaysSilentStallsAgain() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }

        handler.handleDeviceChange()
        settle(handler)
        let revivedAt = harness.clock.now - harness.started
        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.stalls.count, 2)
        XCTAssertEqual(harness.stalls[1] - revivedAt, Policy.maxSecondsWithoutAudio, accuracy: 0.001)
    }

    /// The file is kept across a stall, so a revived capture continues the
    /// recording instead of truncating it.
    func testARevivalContinuesTheSameFile() throws {
        let handler = try harness.makeHandler()
        let file = try XCTUnwrap(handler.outputFile)
        harness.clock.advance(by: 120) { settle(handler) }

        handler.handleDeviceChange()
        settle(handler)

        XCTAssertIdentical(handler.outputFile, file)
    }

    /// The stall's silence is written by the revival's attempt, on the
    /// restart queue before its engine comes up, not by the first revived
    /// buffer's callback: a stall can be an hour, and a write that long in
    /// the callback holds up the capture and live captions behind it.
    func testTheRevivalAttemptWritesTheStallBeforeTheFirstBuffer() throws {
        let handler = try harness.makeHandler()
        let url = try XCTUnwrap(harness.url)
        let gap: TimeInterval = TimelineAnchor.maxGapSeconds + 100
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: harness.hostTime(secondsAgo: gap))
        harness.clock.advance(by: 120) { settle(handler) }

        handler.handleDeviceChange()
        settle(handler)
        XCTAssertTrue(handler.isRecording)
        handler.stop()

        let frames = try Double(AVAudioFile(forReading: url).length)
        XCTAssertGreaterThanOrEqual(frames, (gap - 1) * speechSampleRate, "written with no revived buffer yet")
    }

    /// A stop while the revival's attempt is writing a chunk of the bridge
    /// returns only once that chunk is in the file and the file is closed:
    /// the recorder opens the microphone track the moment `stop()` returns
    /// to build the mix. Returning while the chunk was still on its way, the
    /// mix read a track one chunk short, or with a header not yet written
    /// read it as empty. The hook parks the third chunk between the attempt's
    /// check and its write, the window the stop has to wait out.
    func testAStopWaitsForTheBridgeChunkInFlight() throws {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let chunks = ChunkCounter()
        let handler = try harness.makeHandler {
            guard chunks.next() == 3 else { return }
            parked.signal()
            release.wait()
        }
        let url = try XCTUnwrap(harness.url)
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: harness.hostTime(secondsAgo: 60))
        harness.clock.advance(by: 120) { settle(handler) }

        handler.handleDeviceChange()
        XCTAssertEqual(parked.wait(timeout: .now() + 5), .success, "the bridge reached its third chunk")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { release.signal() }
        handler.stop()
        let atStop = (try? AVAudioFile(forReading: url).length) ?? -1
        handler.restartQueue.sync {}
        let afterwards = try AVAudioFile(forReading: url).length

        XCTAssertGreaterThanOrEqual(afterwards, 3 * AVAudioFramePosition(speechSampleRate), "three chunks of the bridge")
        XCTAssertEqual(atStop, afterwards, "the whole file, closed, as soon as stop() returned")
    }

    /// A stop while the bridge is being written ends the attempt there: the
    /// bridge sees the stop at its next chunk, and nothing after it may open
    /// a microphone the recording no longer wants. The attempt used to go on
    /// to build and start an engine after `stop()` had returned, which opened
    /// the input after the recording ended and, had that call wedged, left
    /// the restart thread stuck in it.
    func testAStopDuringTheBridgeStartsNoEngineAfterIt() throws {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let chunks = ChunkCounter()
        let handler = try harness.makeHandler {
            guard chunks.next() == 2 else { return }
            parked.signal()
            release.wait()
        }
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: harness.hostTime(secondsAgo: 60))
        harness.clock.advance(by: 120) { settle(handler) }
        let before = harness.sessions.count

        handler.handleDeviceChange()
        XCTAssertEqual(parked.wait(timeout: .now() + 5), .success, "the bridge reached its second chunk")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
        handler.stop()
        handler.restartQueue.sync {}
        settle(handler)

        XCTAssertEqual(harness.sessions.count, before, "no engine built after the stop")
    }

    /// A chunk whose write never returns, as on a stuck volume, does not hold
    /// up the stop for longer than its bound: `stop()` runs on the main
    /// thread, and waiting for the write for as long as it is stuck froze the
    /// app with it. Past the bound the stop goes on without the chunk.
    func testAStopWaitsNoLongerThanItsBoundForAChunkThatDoesNotFinish() throws {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let chunks = ChunkCounter()
        let handler = try harness.makeHandler {
            guard chunks.next() == 2 else { return }
            parked.signal()
            release.wait()
        }
        handler.bridgeGate.stopWait = 0.2
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: harness.hostTime(secondsAgo: 60))
        harness.clock.advance(by: 120) { settle(handler) }

        handler.handleDeviceChange()
        XCTAssertEqual(parked.wait(timeout: .now() + 5), .success, "the bridge reached its second chunk")
        // Released long after the bound, so a stop that waits for the chunk
        // is measured rather than hung.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { release.signal() }
        let started = Date()
        handler.stop()
        let waited = Date().timeIntervalSince(started)
        release.signal()
        handler.restartQueue.sync {}

        XCTAssertGreaterThanOrEqual(waited, 0.2, "it waited for the chunk up to its bound")
        XCTAssertLessThan(waited, 1, "and then stopped without it")
    }

    /// A chunk the stop gave up waiting for does not land afterwards. Past
    /// the bound the recorder has the file and may already have moved it;
    /// the bridge used to keep its own handle and write the chunk into the
    /// moved file once it was let go, so the recording changed after it was
    /// handed on. The chunk here is held before its write, where the stop's
    /// give-up can still reach it.
    func testAChunkTheStopGaveUpOnDoesNotLandAfterTheStop() throws {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let chunks = ChunkCounter()
        let handler = try harness.makeHandler {
            guard chunks.next() == 2 else { return }
            parked.signal()
            release.wait()
        }
        handler.bridgeGate.stopWait = 0.02
        let url = try XCTUnwrap(harness.url)
        let moved = url.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: moved) }
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: harness.hostTime(secondsAgo: 60))
        harness.clock.advance(by: 120) { settle(handler) }

        handler.handleDeviceChange()
        XCTAssertEqual(parked.wait(timeout: .now() + 5), .success, "the bridge reached its second chunk")
        handler.stop()
        let atStop = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        try FileManager.default.moveItem(at: url, to: moved)
        release.signal()
        handler.restartQueue.sync {}
        let afterwards = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: moved.path)[.size] as? Int)

        XCTAssertEqual(afterwards, atStop, "nothing written into the moved file after the stop")
    }

    /// A bridge the attempt failed to write is still owed, and the first
    /// revived buffer writes it. Counted as written although it never
    /// landed, the stall went missing from the track and every later sample
    /// sat early by its whole length.
    func testABridgeThatFailedToWriteIsWrittenByTheFirstRevivedBuffer() throws {
        let handler = try harness.makeHandler()
        let url = try XCTUnwrap(harness.url)
        let gap: TimeInterval = 30
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: harness.hostTime(secondsAgo: gap))
        harness.clock.advance(by: 120) { settle(handler) }
        var file = handler.outputFile
        // A file opened for reading throws on every write, as a full disk would.
        handler.outputFile = try AVAudioFile(forReading: url)

        handler.handleDeviceChange()
        settle(handler)
        XCTAssertTrue(handler.isRecording)
        handler.outputFile = file
        file = nil
        try XCTUnwrap(harness.sessions.last).deliver()
        handler.stop()

        let frames = try Double(AVAudioFile(forReading: url).length)
        XCTAssertGreaterThanOrEqual(frames, (gap - 1) * speechSampleRate, "the stall is in the track")
        XCTAssertLessThan(frames, (gap + 5) * speechSampleRate, "once")
    }

    /// After a long stall the bridge takes real time to write, and it is
    /// written before the revival's engine comes up. The attempt deadline is
    /// for an engine that never returns, so it starts once the bridge is
    /// written: counted from the launch, a slow write gave a healthy revival
    /// up for the rest of the recording, logged as a wedged engine.
    func testWritingTheBridgeDoesNotCountAgainstTheAttemptDeadline() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        // Holds the restart queue ahead of the attempt, as a long write would.
        let writing = DispatchSemaphore(value: 0)
        handler.restartQueue.async { writing.wait() }

        handler.handleDeviceChange()
        settle(handler, drainingRestartQueue: false)
        harness.clock.advance(by: RestartArbiter.attemptTimeout + 1) { settle(handler, drainingRestartQueue: false) }
        writing.signal()
        settle(handler)

        XCTAssertEqual(harness.gaveUp, 0)
        XCTAssertTrue(handler.isRecording, "revived once the write was done")
    }

    /// The revived audio lines up with its first buffer's own capture time,
    /// which lies between the attempt starting the engine and the buffer
    /// reaching the callback. Bridged to the adoption, or to the callback,
    /// all of it was off by that latency for the rest of the recording.
    func testRevivedAudioLinesUpWithItsFirstBuffersOwnTime() throws {
        let handler = try harness.makeHandler()
        let url = try XCTUnwrap(harness.url)
        let anchorTicks = try harness.hostTime(secondsAgo: TimelineAnchor.maxGapSeconds + 100)
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: anchorTicks)
        harness.clock.advance(by: 120) { settle(handler) }

        let revivedAt = mach_absolute_time()
        handler.handleDeviceChange()
        settle(handler)
        Thread.sleep(forTimeInterval: 0.6)
        // Captured 300 ms into the revival, delivered well after it.
        let firstTicks = revivedAt + harness.ticks(0.3)
        try XCTUnwrap(harness.sessions.last).deliver(hostTime: firstTicks)
        handler.stop()

        let expected = (machTicksToSeconds(firstTicks) - machTicksToSeconds(anchorTicks)) * speechSampleRate + 160
        XCTAssertEqual(try Double(AVAudioFile(forReading: url).length), expected, accuracy: 40)
    }

    /// A corrupt first timestamp after a revival cannot make the bridge
    /// write more silence than wall-clock time has actually passed.
    func testTheRevivalBridgeIsBoundedByWallClock() throws {
        let handler = try harness.makeHandler()
        let url = try XCTUnwrap(harness.url)
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: harness.hostTime(secondsAgo: TimelineAnchor.maxGapSeconds + 100))
        harness.clock.advance(by: 120) { settle(handler) }

        handler.handleDeviceChange()
        settle(handler)
        try XCTUnwrap(harness.sessions.last).deliver(hostTime: mach_absolute_time() + harness.ticks(86400))
        handler.stop()

        XCTAssertLessThan(
            try Double(AVAudioFile(forReading: url).length),
            (TimelineAnchor.maxGapSeconds + 105) * speechSampleRate,
        )
    }

    /// The track stays aligned to wall-clock across a stall of any length. A
    /// gap longer than the timeline's anomaly cap used to be skipped as a bad
    /// timestamp, which put every later microphone sample that far early
    /// against the app track for the rest of the recording.
    func testARevivalAfterALongStallKeepsTheTrackAlignedToWallClock() throws {
        let handler = try harness.makeHandler()
        let url = try XCTUnwrap(harness.url)
        let gap: TimeInterval = TimelineAnchor.maxGapSeconds + 100
        // One buffer stamped that long ago anchors the track in the past, which
        // is where it would be after a stall of that length.
        try XCTUnwrap(harness.sessions.first).deliver(hostTime: harness.hostTime(secondsAgo: gap))
        harness.clock.advance(by: 120) { settle(handler) }
        XCTAssertEqual(harness.stalls.count, 1)

        handler.handleDeviceChange()
        settle(handler)
        try XCTUnwrap(harness.sessions.last).deliver()
        handler.stop()

        let frames = try Double(AVAudioFile(forReading: url).length)
        XCTAssertGreaterThanOrEqual(frames, (gap - 1) * speechSampleRate, "the stall was bridged with silence")
        XCTAssertLessThan(frames, (gap + 5) * speechSampleRate, "and no more than that")
    }

    /// A revival is a restart like any other: one that wedges gives up at the
    /// attempt deadline, terminally, and is not reported as resumed.
    func testARevivalThatWedgesGivesUpAndIsNotReportedAsResumed() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        XCTAssertEqual(harness.stalls.count, 1)
        let beforeRevival = harness.sessions.count
        harness.factory.script([{ $0.shouldWedge = true }])

        handler.handleDeviceChange()
        waitForSessions(harness.factory, count: beforeRevival + 1)
        let wedged = try XCTUnwrap(harness.sessions.last)
        wait(for: [wedged.entered], timeout: 5)
        // It armed its deadline on the main queue before it wedged.
        settle(handler, drainingRestartQueue: false)
        harness.clock.advance(by: 60) { settle(handler, drainingRestartQueue: false) }

        XCTAssertEqual(harness.gaveUp, 1)
        XCTAssertEqual(harness.resumes, 0)
        XCTAssertEqual(wedged.teardowns, 0)
    }
}

/// Counts the bridge's chunks across the restart queue and the test.
private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
