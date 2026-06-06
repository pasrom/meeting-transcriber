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

    // MARK: - Resampled forward (the normal capture-write path)

    /// The seam PR-1 changes: the resampled 16 kHz mono buffer that
    /// `writeCapturedBuffer` writes to the file fd is the SAME buffer handed to
    /// the live sink. Feeds one second of 48 kHz interleaved stereo through the
    /// real converter and asserts the sink received 16 kHz mono — so the app
    /// side never resamples a second time. `resampleForwardAndWrite` is the
    /// parameterised core of `writeCapturedBuffer` (drivable without a live
    /// CATap, which can't set `actualSampleRate`).
    func test_resampleForwardAndWrite_forwardsResampled16kMonoToSink() {
        let recorder = SinkRecorder()
        let capture = makeCapture(sampleRate: 48000, channels: 2) { recorder.sink($0) }

        // 1 s of 48 kHz interleaved stereo, L=0.4 R=0.6 → mono average 0.5.
        var stereo = [Float]()
        stereo.reserveCapacity(48000 * 2)
        for _ in 0 ..< 48000 {
            stereo.append(0.4)
            stereo.append(0.6)
        }

        capture.resampleForwardAndWrite(
            fd: devNullFD, interleaved: stereo,
            inputRate: 48000, inputChannels: 2, hostTicks: mach_absolute_time(),
        )

        XCTAssertEqual(recorder.buffers.count, 1, "sink must receive exactly the one resampled buffer")
        let delivered = recorder.buffers[0]
        XCTAssertEqual(delivered.sampleRate, 16000, "sink must get 16 kHz, not the raw 48 kHz device rate")
        XCTAssertEqual(delivered.channelCount, 1, "sink must get mono, not the raw 2-channel stereo")
        // 48 k stereo (96000 interleaved samples) → ~16000 mono. Allow converter
        // priming slop, matching StreamingMonoResamplerTests' ±300 tolerance.
        XCTAssertEqual(
            delivered.samples.count, 16000, accuracy: 300,
            "1 s of 48 kHz stereo → ~16000 mono samples (≈ input frames / 3)",
        )
        let mid = delivered.samples[delivered.samples.count / 2]
        XCTAssertEqual(mid, 0.5, accuracy: 0.05, "stereo must downmix to the channel average")
    }

    /// THE gap-fill contract: a device-restart timeline gap is filled with
    /// silence in the FILE only, never forwarded to the live sink. The file is
    /// `sink samples + silence`; the sink sees only real audio. A regression
    /// that routed gap-fill silence (or the silence-padded buffer) to the sink
    /// would make captions transcribe a block of zeros as a phantom utterance.
    ///
    /// Drives `resampleForwardAndWrite` twice with 1 s of 48 kHz stereo each,
    /// the second call's `hostTicks` 3 s after the first. The `TimelineAnchor`
    /// self-anchors on the first call (no silence) and bridges the ~2 s gap
    /// (3 s wall-clock minus 1 s already written) on the second.
    func test_resampleForwardAndWrite_gapFillSilenceIsFileOnly() {
        let recorder = SinkRecorder()
        let capture = makeCapture(sampleRate: 48000, channels: 2) { recorder.sink($0) }

        let path = NSTemporaryDirectory() + "livesink_gap_\(UUID().uuidString).f32"
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0, "couldn't open temp file")
        defer { close(fd); unlink(path) }

        let oneSecond48kStereo = stereoFrames(count: 48000, left: 0.4, right: 0.6)
        let t0 = mach_absolute_time()
        capture.resampleForwardAndWrite(
            fd: fd, interleaved: oneSecond48kStereo,
            inputRate: 48000, inputChannels: 2, hostTicks: t0,
        )
        // Buffer 2 presents 3 s after t0 → ~2 s restart gap before it.
        let t1 = t0 + secondsToMachTicks(3.0)
        capture.resampleForwardAndWrite(
            fd: fd, interleaved: oneSecond48kStereo,
            inputRate: 48000, inputChannels: 2, hostTicks: t1,
        )

        // Every sink buffer is 16 kHz mono real audio…
        XCTAssertEqual(recorder.buffers.count, 2, "two real buffers, no gap-fill buffer")
        for buf in recorder.buffers {
            XCTAssertEqual(buf.sampleRate, 16000)
            XCTAssertEqual(buf.channelCount, 1)
        }
        let sinkSamples = recorder.buffers.reduce(0) { $0 + $1.samples.count }

        // …and the file is exactly sink audio + gap-fill silence. The silence
        // block (file − sink) must account for the ~2 s gap (allowing for
        // converter priming slop on each span). If silence had been forwarded
        // to the sink, this delta would collapse toward zero.
        let fileFrames = Int(lseek(fd, 0, SEEK_END)) / MemoryLayout<Float>.size
        let silenceFrames = fileFrames - sinkSamples
        XCTAssertGreaterThanOrEqual(
            silenceFrames, Int(1.5 * 16000),
            "the ~2 s gap must reach the file as ≥1.5 s of silence (file = sink + silence)",
        )
        // The sink itself received none of that silence: its total is just the
        // two real spans (~2 × 16000), well under the file total.
        XCTAssertLessThan(
            sinkSamples, fileFrames - Int(1.0 * 16000),
            "sink must carry no gap-fill silence — file strictly exceeds sink by the gap",
        )
    }

    /// HFP↔A2DP renegotiation shape: the device rate changes mid-recording
    /// (48 kHz → 24 kHz on the same capture instance). The resampler must
    /// rebuild its converter so each 1 s span still maps to ~1 s of 16 kHz
    /// mono — and every forwarded sink buffer stays 16 kHz mono regardless of
    /// the changing input rate.
    func test_resampleForwardAndWrite_rateChangeKeepsSinkAt16kMono() {
        let recorder = SinkRecorder()
        let capture = makeCapture(sampleRate: 48000, channels: 2) { recorder.sink($0) }

        let path = NSTemporaryDirectory() + "livesink_rate_\(UUID().uuidString).f32"
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0, "couldn't open temp file")
        defer { close(fd); unlink(path) }

        let t0 = mach_absolute_time()
        capture.resampleForwardAndWrite(
            fd: fd, interleaved: stereoFrames(count: 48000, left: 0.4, right: 0.6),
            inputRate: 48000, inputChannels: 2, hostTicks: t0,
        )
        // 24 kHz span, contiguous in wall-clock (t0 + 1 s) so no gap-fill —
        // isolates the rate-change behaviour from the gap-fill path.
        let t1 = t0 + secondsToMachTicks(1.0)
        capture.resampleForwardAndWrite(
            fd: fd, interleaved: stereoFrames(count: 24000, left: 0.4, right: 0.6),
            inputRate: 24000, inputChannels: 2, hostTicks: t1,
        )

        XCTAssertEqual(recorder.buffers.count, 2)
        for buf in recorder.buffers {
            XCTAssertEqual(buf.sampleRate, 16000, "sink stays 16 kHz across the rate change")
            XCTAssertEqual(buf.channelCount, 1, "sink stays mono across the rate change")
        }
        // Two 1 s spans → ~32000 mono samples total. A stale converter fed the
        // 24 kHz span as 48 kHz would yield ~half that span (~8000) — far
        // outside the ±10 % tolerance allowed for the converter rebuild/priming.
        let sinkSamples = recorder.buffers.reduce(0) { $0 + $1.samples.count }
        XCTAssertEqual(
            sinkSamples, 32000, accuracy: 3200,
            "1 s @48 kHz + 1 s @24 kHz → ~32000 mono samples after converter rebuild",
        )
    }

    /// FIRST-buffer priming probe: a tiny first buffer (64 samples = 32 frames
    /// of 48 kHz stereo) into a fresh capture deterministically yields exactly
    /// one short, NON-empty resampled buffer (5 mono samples, verified across
    /// trials). The contract this pins: the resampler never hands the live sink
    /// an EMPTY `[Float]` — `resampleForwardAndWrite`'s `guard !mono16k.isEmpty`
    /// plus `forwardToLiveSink(monoSamples:)`'s own non-empty guard ensure a
    /// priming-only buffer is dropped rather than forwarded as a zero-length
    /// caption span. (The converter does emit a few samples even for tiny input,
    /// so we assert non-empty delivery rather than zero calls.)
    func test_resampleForwardAndWrite_primingEmitsNoEmptyBuffer() {
        let recorder = SinkRecorder()
        let capture = makeCapture(sampleRate: 48000, channels: 2) { recorder.sink($0) }

        let path = NSTemporaryDirectory() + "livesink_prime_\(UUID().uuidString).f32"
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0, "couldn't open temp file")
        defer { close(fd); unlink(path) }

        let tinyFirst = stereoFrames(count: 32, left: 0.4, right: 0.6) // 64 interleaved samples
        capture.resampleForwardAndWrite(
            fd: fd, interleaved: tinyFirst,
            inputRate: 48000, inputChannels: 2, hostTicks: mach_absolute_time(),
        )

        // The converter emits samples for tiny input, so the sink IS called —
        // and what it gets must be a real, non-empty 16 kHz mono buffer.
        XCTAssertFalse(recorder.buffers.isEmpty, "tiny input still yields a (short) resampled buffer")
        for buf in recorder.buffers {
            XCTAssertFalse(buf.samples.isEmpty, "the sink must never receive an empty priming buffer")
            XCTAssertEqual(buf.sampleRate, 16000)
            XCTAssertEqual(buf.channelCount, 1)
        }
    }

    // MARK: - Private helpers

    /// Build `count` interleaved stereo frames with the given L/R values.
    private func stereoFrames(count: Int, left: Float, right: Float) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(count * 2)
        for _ in 0 ..< count {
            samples.append(left)
            samples.append(right)
        }
        return samples
    }
}
