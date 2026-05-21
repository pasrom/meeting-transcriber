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

    // MARK: - tick() report path

    func testFirstTickReturnsNilAndArmsInterval() {
        // The first call seeds `nextReportTicks`; no snapshot is emitted on
        // the very first invocation regardless of how much data has been fed.
        var reporter = DebugRMSReporter()
        reporter.add(sumSq: 100 * 0.5 * 0.5, samples: 100)
        XCTAssertNil(reporter.tick(intervalSeconds: 0))
    }

    func testSecondTickAfterIntervalEmitsSnapshotAndResetsAccumulators() throws {
        var reporter = DebugRMSReporter()
        reporter.add(sumSq: 100 * 0.5 * 0.5, samples: 100)

        // First tick arms the interval (effectively zero).
        XCTAssertNil(reporter.tick(intervalSeconds: 0))

        // The second tick is past the (zero) interval — must report.
        let snapshot = try XCTUnwrap(reporter.tick(intervalSeconds: 0))
        // sumSq=25 over 100 samples → meanSq=0.25 → RMS=0.5 → ~-6.02 dBFS.
        XCTAssertEqual(snapshot.dBFS, -6.02, accuracy: 0.02)
        XCTAssertEqual(snapshot.samples, 100)

        // Accumulators reset after a fired snapshot; a follow-up tick with
        // no new data reports the empty-input floor (-120 dBFS).
        let next = try XCTUnwrap(reporter.tick(intervalSeconds: 0))
        XCTAssertEqual(next.dBFS, -120, accuracy: 0.001)
        XCTAssertEqual(next.samples, 0)
    }

    func testTickReportsFloorWhenNoSamplesAccumulated() throws {
        // Guards against divide-by-zero when no `add(...)` calls have run.
        var reporter = DebugRMSReporter()
        XCTAssertNil(reporter.tick(intervalSeconds: 0))
        let snapshot = try XCTUnwrap(reporter.tick(intervalSeconds: 0))
        XCTAssertEqual(snapshot.dBFS, -120, accuracy: 0.001)
        XCTAssertEqual(snapshot.samples, 0)
    }

    func testTickReportsFloorWhenAccumulatedEnergyIsZero() throws {
        var reporter = DebugRMSReporter()
        reporter.add(sumSq: 0, samples: 100)
        XCTAssertNil(reporter.tick(intervalSeconds: 0))
        let snapshot = try XCTUnwrap(reporter.tick(intervalSeconds: 0))
        XCTAssertEqual(snapshot.dBFS, -120, accuracy: 0.001)
        XCTAssertEqual(snapshot.samples, 100)
    }

    func testTickIntervalThrottlesEmission() {
        var reporter = DebugRMSReporter()
        XCTAssertNil(reporter.tick(intervalSeconds: 3600))
        reporter.add(sumSq: 100 * 0.5 * 0.5, samples: 100)
        // Within the same hour, a follow-up tick must NOT emit.
        XCTAssertNil(reporter.tick(intervalSeconds: 3600))
    }
}
