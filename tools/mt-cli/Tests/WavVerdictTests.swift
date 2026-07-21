@testable import mt_cli
import XCTest

final class WavVerdictTests: XCTestCase {
    private let sampleRate = 16000.0

    // MARK: - Synthetic sample generators (no file I/O)

    /// A sine whose windowed RMS sits at `rmsDBFS` (rms = amp / sqrt(2)).
    private func sine(rmsDBFS: Double, seconds: Double, freq: Double = 440) -> [Float] {
        let amp = pow(10, rmsDBFS / 20) * 2.0.squareRoot()
        let count = Int(seconds * sampleRate)
        return (0 ..< count).map { Float(amp * sin(2 * Double.pi * freq * Double($0) / sampleRate)) }
    }

    /// A constant DC level whose RMS is exactly `dBFS` (rms = |value|).
    private func constant(dBFS: Double, seconds: Double) -> [Float] {
        let value = Float(pow(10, dBFS / 20))
        return [Float](repeating: value, count: Int(seconds * sampleRate))
    }

    // MARK: - Tests

    func testPureSilenceIsSilent() {
        let v = WavVerdict.analyze(samples: [Float](repeating: 0, count: 16000), sampleRate: sampleRate)
        XCTAssertTrue(v.isSilent)
        XCTAssertEqual(v.activeWindowRatio, 0)
        XCTAssertEqual(v.peakWindowRMSdBFS, WavVerdict.silenceFloorDBFS)
    }

    func testVeryQuietSignalIsSilent() {
        // -90 dBFS is real signal but well below the -50 threshold → silent.
        let v = WavVerdict.analyze(samples: constant(dBFS: -90, seconds: 1), sampleRate: sampleRate)
        XCTAssertTrue(v.isSilent)
        XCTAssertEqual(v.activeWindowRatio, 0)
        XCTAssertEqual(v.peakWindowRMSdBFS, -90, accuracy: 0.5)
    }

    func testSustainedToneIsNotSilentWithFullActiveRatio() {
        let v = WavVerdict.analyze(samples: sine(rmsDBFS: -20, seconds: 1), sampleRate: sampleRate)
        XCTAssertFalse(v.isSilent)
        XCTAssertEqual(v.activeWindowRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(v.peakWindowRMSdBFS, -20, accuracy: 1.0)
    }

    func testBriefToneInLongSilenceHasLowActiveRatio() {
        // 1 s tone + 9 s silence: peak is loud (not silent), but only ~10% of
        // the 0.5 s windows are active — the guard against a "1 s blip" pass.
        var samples = sine(rmsDBFS: -20, seconds: 1)
        samples += [Float](repeating: 0, count: Int(9 * sampleRate))
        let v = WavVerdict.analyze(samples: samples, sampleRate: sampleRate)
        XCTAssertFalse(v.isSilent)
        XCTAssertEqual(v.windowCount, 20)
        XCTAssertEqual(v.activeWindowRatio, 0.1, accuracy: 0.05)
    }

    func testClipShorterThanOneWindowIsAnalyzedAsOneWindow() {
        // 100 samples, window is 8000 — must not crash or divide by zero.
        let v = WavVerdict.analyze(samples: sine(rmsDBFS: -10, seconds: 0.006), sampleRate: sampleRate)
        XCTAssertEqual(v.windowCount, 1)
        XCTAssertFalse(v.isSilent)
    }

    func testEmptySamplesAreSilent() {
        let v = WavVerdict.analyze(samples: [], sampleRate: sampleRate)
        XCTAssertTrue(v.isSilent)
        XCTAssertEqual(v.peakWindowRMSdBFS, WavVerdict.silenceFloorDBFS)
    }
}
