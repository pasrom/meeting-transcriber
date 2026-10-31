// swiftlint:disable single_test_class
@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

final class MicMuteTimelineTests: XCTestCase {
    func testClosedIntervalSpansTheWrittenTrack() {
        var timeline = MicMuteTimeline()
        timeline.advance(to: 2)
        timeline.setMuted(true)
        timeline.advance(to: 5)
        timeline.setMuted(false)
        XCTAssertEqual(timeline.closed, [MicMuteInterval(start: 2, end: 5)])
        XCTAssertFalse(timeline.isMuted)
    }

    func testRepeatedMuteKeepsTheFirstStart() {
        var timeline = MicMuteTimeline()
        timeline.setMuted(true)
        timeline.advance(to: 3)
        timeline.setMuted(true)
        XCTAssertEqual(timeline.openSince, 0)
    }

    func testToggleWithNothingWrittenRecordsNoInterval() {
        var timeline = MicMuteTimeline()
        timeline.setMuted(true)
        timeline.setMuted(false)
        XCTAssertTrue(timeline.closed.isEmpty)
    }

    func testOpenIntervalClosesAtTheGivenEnd() {
        var timeline = MicMuteTimeline()
        timeline.advance(to: 1)
        timeline.setMuted(true)
        XCTAssertEqual(timeline.intervals(endingAt: 9), [MicMuteInterval(start: 1, end: 9)])
    }

    func testOpenIntervalSurvivesEncoding() throws {
        var timeline = MicMuteTimeline()
        timeline.advance(to: 4)
        timeline.setMuted(true)
        let decoded = try JSONDecoder().decode(
            MicMuteTimeline.self, from: JSONEncoder().encode(timeline),
        )
        XCTAssertEqual(decoded, timeline)
    }
}

/// Drives real buffers through the production tap block, so what is asserted is
/// what reaches the file and the live captions.
final class MicCaptureHandlerMuteTests: XCTestCase {
    private final class TapSession: MicEngineSessionProviding {
        let notificationObject: AnyObject = NSObject()
        let format: AVAudioFormat
        var tapBlock: AVAudioNodeTapBlock?

        init(format: AVAudioFormat) {
            self.format = format
        }

        // swiftlint:disable:next unneeded_throws_rethrows
        func hardwareFormat(deviceUID _: String?) throws -> AVAudioFormat {
            format
        }

        func installTap(format _: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
            tapBlock = block
        }

        func start() {}
        func teardown() {}
    }

    private final class SinkLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Float] = []

        var samples: [Float] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func append(_ new: [Float]) {
            lock.lock(); stored += new; lock.unlock()
        }
    }

    private var url = URL(fileURLWithPath: "/")

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic_mute_\(UUID().uuidString).wav")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    private func loud(_ format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< Int(frames) {
                buffer.floatChannelData?[channel][frame] = frame.isMultiple(of: 2) ? 0.5 : -0.5
            }
        }
        return buffer
    }

    private func make(
        rate: Double, sink: SinkLog? = nil,
    ) throws -> (MicCaptureHandler, TapSession) {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let session = TapSession(format: format)
        var liveSink: LiveAudioSink?
        if let sink {
            liveSink = { buffer in sink.append(buffer.samples) }
        }
        let handler = MicCaptureHandler(
            outputURL: url, liveSink: liveSink, sessionFactory: { session }, // swiftlint:disable:this trailing_closure
        )
        try handler.start()
        return (handler, session)
    }

    private func deliver(_ session: TapSession, frames: AVAudioFrameCount) throws {
        let when = AVAudioTime(hostTime: mach_absolute_time())
        try session.tapBlock?(loud(session.format, frames: frames), when)
    }

    private func writtenSamples() throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length),
        ))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func testMutedBuffersKeepTheTrackLengthButCarryNoSignal() throws {
        let (handler, session) = try make(rate: speechSampleRate)
        try deliver(session, frames: 1600)
        handler.setMuted(true)
        try deliver(session, frames: 1600)
        handler.setMuted(false)
        try deliver(session, frames: 1600)
        let intervals = handler.muteIntervals
        handler.stop()

        let samples = try writtenSamples()
        XCTAssertEqual(samples.count, 4800)
        XCTAssertTrue(samples[0 ..< 1600].contains { $0 != 0 })
        XCTAssertTrue(samples[1600 ..< 3200].allSatisfy { $0 == 0 })
        XCTAssertTrue(samples[3200 ..< 4800].contains { $0 != 0 })
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(try XCTUnwrap(intervals.first).start, 0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(intervals.first).end, 0.2, accuracy: 0.001)
    }

    func testMuteSilencesAudioThatNeedsResampling() throws {
        let (handler, session) = try make(rate: 48000)
        handler.setMuted(true)
        try deliver(session, frames: 4800)
        handler.stop()

        let samples = try writtenSamples()
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }

    func testLiveCaptionsReceiveSilenceNotMutedSpeech() throws {
        let sink = SinkLog()
        let (handler, session) = try make(rate: speechSampleRate, sink: sink)
        handler.setMuted(true)
        try deliver(session, frames: 1600)
        handler.stop()

        XCTAssertEqual(sink.samples.count, 1600, "silence, so the open caption can finish")
        XCTAssertTrue(sink.samples.allSatisfy { $0 == 0 })
    }

    func testHealthChecksStillSeeTheRealLevelWhileMuted() throws {
        let (handler, session) = try make(rate: speechSampleRate)
        handler.setMuted(true)
        try deliver(session, frames: 1600)

        XCTAssertGreaterThan(handler.currentLevelDBFS, -20)
        XCTAssertNotNil(handler.currentSignalAges.secondsSinceLastEnergy)
        handler.stop()
    }

    func testMuteStillOpenAtStopRunsToTheEndOfTheTrack() throws {
        let (handler, session) = try make(rate: speechSampleRate)
        try deliver(session, frames: 1600)
        handler.setMuted(true)
        try deliver(session, frames: 1600)
        handler.stop()

        let interval = try XCTUnwrap(handler.muteIntervals.first)
        XCTAssertEqual(interval.end, 0.2, accuracy: 0.001)
    }
}
