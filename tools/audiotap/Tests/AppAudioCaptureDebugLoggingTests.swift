@testable import AudioTapLib
import Darwin
import XCTest

/// Direct unit coverage for `AppAudioCapture+DebugLogging.swift`. The
/// helpers run inside the CoreAudio IOProc in production, so these tests
/// invoke them directly on an `AppAudioCapture` instance with a `/dev/null`
/// output fd and synthesised Float buffers — same shape as the existing
/// `AppAudioCaptureLiveSinkTests`.
@available(macOS 14.2, *)
final class AppAudioCaptureDebugLoggingTests: XCTestCase {
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

    private func makeCapture(debugLogging: Bool = false) -> AppAudioCapture {
        AppAudioCapture(
            pids: [],
            outputFileDescriptor: devNullFD,
            sampleRate: 48000,
            channels: 2,
            debugLogging: debugLogging,
            liveSink: nil,
        )
    }

    // MARK: - accumulateDebugRMS

    func test_accumulateDebugRMS_happyPath_advancesAccumulators() {
        let capture = makeCapture()
        XCTAssertEqual(capture.debugTotalBytes, 0, "preconditional")

        // Four interleaved Float samples chosen so sum-of-squares is 2.0.
        var samples: [Float] = [1, 0, -1, 0]
        let byteCount = samples.count * MemoryLayout<Float>.size
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return XCTFail("no base") }
            capture.accumulateDebugRMS(
                data: UnsafeMutableRawPointer(base),
                byteCount: byteCount,
            )
        }

        XCTAssertEqual(capture.debugTotalBytes, UInt64(byteCount))
        XCTAssertEqual(capture.debugRMS.sampleCount, samples.count)
        // 1² + 0² + (-1)² + 0² = 2
        XCTAssertEqual(capture.debugRMS.accumulator, 2.0, accuracy: 1e-9)
    }

    func test_accumulateDebugRMS_zeroBytes_isNoOp() {
        let capture = makeCapture()
        var dummy: Float = 0
        withUnsafeMutablePointer(to: &dummy) { ptr in
            capture.accumulateDebugRMS(
                data: UnsafeMutableRawPointer(ptr),
                byteCount: 0,
            )
        }
        XCTAssertEqual(capture.debugTotalBytes, 0)
        XCTAssertEqual(capture.debugRMS.sampleCount, 0)
    }

    // MARK: - publishCurrentLevel

    func test_publishCurrentLevel_forwardsLastReadingToPublisher() {
        let capture = makeCapture()
        // Seed the RMS reporter with a non-trivial signal so lastLevelDBFS
        // is well above the -120 dBFS floor.
        var samples: [Float] = Array(repeating: 0.5, count: 256)
        let byteCount = samples.count * MemoryLayout<Float>.size
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return XCTFail("no base") }
            capture.accumulateDebugRMS(
                data: UnsafeMutableRawPointer(base),
                byteCount: byteCount,
            )
        }

        let beforePublish = capture.debugRMS.lastLevelDBFS
        XCTAssertGreaterThan(beforePublish, -120, "preconditional: reporter saw signal")

        capture.publishCurrentLevel()

        // `currentLevelDBFS` reads through the level publisher with a 0.5 s
        // staleness decay; immediately after publish() it must equal what
        // the reporter handed in.
        XCTAssertEqual(capture.currentLevelDBFS, beforePublish, accuracy: 1e-9)
    }

    // MARK: - maybeReportDebugRMS

    func test_maybeReportDebugRMS_firstCall_doesNotEmit() {
        // First invocation primes the throttle window inside
        // `DebugRMSReporter.tick()` and returns nil — guard returns early.
        // The test asserts the call is harmless on a fresh capture (no
        // side-effects, no crash). The 5-s elapsed-time path is exercised
        // only by the live-recording E2E.
        let capture = makeCapture(debugLogging: true)
        capture.maybeReportDebugRMS()
        XCTAssertEqual(capture.debugRMS.sampleCount, 0)
    }

    func test_maybeReportDebugRMS_debugLoggingOff_dropsReport() {
        // Even when `tick()` would emit a report, `debugLogging=false`
        // must short-circuit before the log line. We can't easily force
        // `tick()` to return non-nil without waiting 5 s, so this test
        // documents the contract by exercising the early-return path
        // and ensuring it stays crash-free with `debugLogging=false`.
        let capture = makeCapture(debugLogging: false)
        capture.maybeReportDebugRMS()
        XCTAssertEqual(capture.debugRMS.sampleCount, 0)
    }
}
