@testable import AudioTapLib
import XCTest

final class DebugRMSReporterTests: XCTestCase {
    // MARK: - lastLevelDBFS (instantaneous, per-add())

    func testInitialLastLevelIsFloor() {
        let reporter = DebugRMSReporter()
        XCTAssertEqual(reporter.lastLevelDBFS, -120, accuracy: 0.001)
    }

    func testAddUpdatesLastLevelToInstantaneousRMS() {
        var reporter = DebugRMSReporter()
        // 100 samples of constant value 0.5 → mean square 0.25 → RMS 0.5 → 20*log10(0.5) ≈ -6.0206 dBFS
        let sumSq = 100 * 0.5 * 0.5
        reporter.add(sumSq: sumSq, samples: 100)
        XCTAssertEqual(reporter.lastLevelDBFS, -6.0206, accuracy: 0.01)
    }

    func testZeroSamplesIsFloor() {
        var reporter = DebugRMSReporter()
        reporter.add(sumSq: 0, samples: 100)
        XCTAssertEqual(reporter.lastLevelDBFS, -120, accuracy: 0.001)
    }

    func testEmptyAddIsIgnored() {
        var reporter = DebugRMSReporter()
        // Seed with a real reading.
        reporter.add(sumSq: 1.0, samples: 100)
        let seeded = reporter.lastLevelDBFS
        // An empty add (no samples) must not perturb the last level.
        reporter.add(sumSq: 0, samples: 0)
        XCTAssertEqual(reporter.lastLevelDBFS, seeded, accuracy: 0.001)
    }

    func testLastLevelTracksConsecutiveAdds() {
        var reporter = DebugRMSReporter()
        // Loud burst.
        reporter.add(sumSq: 100 * 0.5 * 0.5, samples: 100)
        XCTAssertEqual(reporter.lastLevelDBFS, -6.02, accuracy: 0.02)
        // Quiet next.
        reporter.add(sumSq: 100 * 0.01 * 0.01, samples: 100)
        XCTAssertEqual(reporter.lastLevelDBFS, -40, accuracy: 0.02)
    }

    // MARK: - lastLevelDBFS independent of tick() throttling

    func testLastLevelIndependentOfTick() {
        var reporter = DebugRMSReporter()
        reporter.add(sumSq: 100 * 0.5 * 0.5, samples: 100)
        // tick() with a long interval should return nil but must not reset lastLevelDBFS.
        _ = reporter.tick(intervalSeconds: 3600)
        XCTAssertEqual(reporter.lastLevelDBFS, -6.02, accuracy: 0.02)
    }
}
