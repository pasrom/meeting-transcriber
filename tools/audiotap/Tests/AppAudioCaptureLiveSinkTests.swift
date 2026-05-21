@testable import AudioTapLib
import Darwin
import XCTest

/// Direct unit coverage for `AppAudioCapture+LiveSink.swift`. The IOProc
/// callback that calls `forwardToLiveSink` only runs inside CoreAudio, so
/// these tests drive the helper directly with a synthesised Float buffer
/// and assert on what the sink receives.
@available(macOS 14.2, *)
final class AppAudioCaptureLiveSinkTests: XCTestCase {
    /// Captures every `LiveAudioBuffer` the sink is handed. Reference type
    /// so the `@Sendable` closure can mutate it.
    private final class SinkRecorder: @unchecked Sendable {
        var buffers: [LiveAudioBuffer] = []
        func sink(_ buffer: LiveAudioBuffer) {
            buffers.append(buffer)
        }
    }

    /// /dev/null fd so the constructor's `outputFileDescriptor` is happy
    /// without producing real files. Closed in tearDown.
    private var devNullFD: Int32 = -1

    override func setUp() {
        super.setUp()
        devNullFD = open("/dev/null", O_WRONLY)
        XCTAssertGreaterThanOrEqual(devNullFD, 0, "couldn't open /dev/null")
    }

    override func tearDown() {
        if devNullFD >= 0 { close(devNullFD) }
        devNullFD = -1
        super.tearDown()
    }

    private func makeCapture(
        sampleRate: Int = 48000,
        channels: Int = 2,
        sink: LiveAudioSink? = nil,
    ) -> AppAudioCapture {
        AppAudioCapture(
            pids: [],
            outputFileDescriptor: devNullFD,
            sampleRate: sampleRate,
            channels: channels,
            debugLogging: false,
            liveSink: sink,
        )
    }

    // MARK: - Guard cases

    func test_forwardToLiveSink_nilSink_isNoOp() {
        let capture = makeCapture(sink: nil)
        // Allocate one sample worth of data so byteCount > 0 — verifies
        // the nil-sink guard short-circuits BEFORE the sampleCount check.
        var sample: Float = 0.5
        withUnsafeMutablePointer(to: &sample) { ptr in
            capture.forwardToLiveSink(
                data: UnsafeMutableRawPointer(ptr),
                byteCount: MemoryLayout<Float>.size,
            )
        }
        // No assertion possible beyond "didn't crash" — the absence of a
        // sink means no observable side-effect. Crash-free is the
        // contract.
    }

    func test_forwardToLiveSink_zeroBytes_skipsSink() {
        let recorder = SinkRecorder()
        let capture = makeCapture { recorder.sink($0) }
        // byteCount=0 → sampleCount=0 → guard fires, sink not called.
        var dummy: Float = 0
        withUnsafeMutablePointer(to: &dummy) { ptr in
            capture.forwardToLiveSink(
                data: UnsafeMutableRawPointer(ptr),
                byteCount: 0,
            )
        }
        XCTAssertTrue(recorder.buffers.isEmpty)
    }

    // MARK: - Happy path

    func test_forwardToLiveSink_copiesSamplesAndForwards() {
        let recorder = SinkRecorder()
        let capture = makeCapture(sampleRate: 48000, channels: 2) { recorder.sink($0) }

        // 4 interleaved stereo samples (= 2 frames stereo). Values are
        // distinct so we can confirm the byte order survives the
        // pointer → [Float] conversion intact.
        var samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let byteCount = samples.count * MemoryLayout<Float>.size
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return XCTFail("no base") }
            capture.forwardToLiveSink(
                data: UnsafeMutableRawPointer(base),
                byteCount: byteCount,
            )
        }

        XCTAssertEqual(recorder.buffers.count, 1)
        let delivered = recorder.buffers[0]
        XCTAssertEqual(delivered.samples, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
        // Channel count comes from `actualChannels` (which is 0 until
        // startCapture queries the device) clamped to ≥1. The init
        // `channels` argument is never consulted by the helper —
        // covered in detail by `test_…_clampsChannelCount_atLeastOne`.
        XCTAssertEqual(delivered.channelCount, 1)
        XCTAssertEqual(delivered.sampleRate, 48000)
        XCTAssertGreaterThan(delivered.hostTime, 0)
    }

    // MARK: - Fallback branches

    /// `actualSampleRate` defaults to 0 until `startCapture()` queries the
    /// device. The helper falls back to the constructor's declared
    /// `sampleRate` in that window. Test the fallback path explicitly.
    func test_forwardToLiveSink_usesDeclaredRate_whenActualUnset() {
        let recorder = SinkRecorder()
        let capture = makeCapture(sampleRate: 44100, channels: 2) { recorder.sink($0) }
        XCTAssertEqual(capture.actualSampleRate, 0, "preconditional: actual is 0 pre-start")

        var samples: [Float] = [1, 2, 3, 4]
        let byteCount = samples.count * MemoryLayout<Float>.size
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return XCTFail("no base") }
            capture.forwardToLiveSink(
                data: UnsafeMutableRawPointer(base),
                byteCount: byteCount,
            )
        }
        XCTAssertEqual(recorder.buffers[0].sampleRate, 44100)
    }

    /// `actualChannels` defaults to 0 pre-start. `max(actualChannels, 1)`
    /// must clamp to 1 in that window — guards against a divide-by-zero
    /// downstream in any consumer.
    func test_forwardToLiveSink_clampsChannelCount_atLeastOne() {
        let recorder = SinkRecorder()
        let capture = makeCapture(sampleRate: 48000, channels: 0) { recorder.sink($0) }
        XCTAssertEqual(capture.actualChannels, 0)

        var samples: [Float] = [0.1, 0.2]
        let byteCount = samples.count * MemoryLayout<Float>.size
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return XCTFail("no base") }
            capture.forwardToLiveSink(
                data: UnsafeMutableRawPointer(base),
                byteCount: byteCount,
            )
        }
        XCTAssertEqual(recorder.buffers[0].channelCount, 1, "must clamp to 1")
    }
}
