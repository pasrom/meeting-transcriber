@testable import MeetingTranscriber
import XCTest

/// A recording recovered from staging takes its mic delay from the recording
/// sidecar the watch loop wrote beside its mix, instead of zero, which
/// shifted the dual-track merge and the echo detector's lag search. Only its
/// own sidecar: one under another stem, or one naming another mix, is not
/// this recording's.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class OrphanRecoverySidecarTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var recordings: URL!

    override func setUp() async throws {
        try await super.setUp()
        recordings = try makeTempDirectory(prefix: "OrphanRecoverySidecarTests").appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    /// A dual-source recording in staging, with its sidecar when `delay` is given.
    @discardableResult
    private func stage(_ stem: String, delay: TimeInterval? = nil, sidecarMix: String? = nil) throws -> URL {
        for suffix in RecordingFileSuffix.all {
            try Data(repeating: 0xFF, count: 100).write(to: recordings.appendingPathComponent(stem + suffix))
        }
        let mix = recordings.appendingPathComponent(stem + RecordingFileSuffix.mix)
        if let delay {
            try RecordingSidecar(
                title: "Standup", appName: "Teams", startedAt: Date(), stoppedAt: Date(),
                participants: [], micDelaySeconds: delay, trigger: .auto,
                mixFilename: sidecarMix ?? mix.lastPathComponent,
                appFilename: stem + RecordingFileSuffix.app, micFilename: stem + RecordingFileSuffix.mic,
            ).write(to: XCTUnwrap(RecordingSidecar.recordingSidecarURL(besideMix: mix)))
        }
        return mix
    }

    /// The recovered jobs' mic delays, keyed by mix file name.
    private func recoveredDelays() async -> [String: TimeInterval] {
        let queue = PipelineQueue(logDir: recordings.deletingLastPathComponent(), stagingDir: recordings)
        await queue.recoverOrphanedRecordings(recordingsDir: recordings)
        return Dictionary(uniqueKeysWithValues: queue.jobs.compactMap { job in
            job.mixPath.map { ($0.lastPathComponent, job.micDelay) }
        })
    }

    func testARecoveredRecordingTakesItsMicDelayFromTheStagingSidecar() async throws {
        let mix = try stage("20260311_090000", delay: 0.375)

        let delays = await recoveredDelays()

        XCTAssertEqual(delays[mix.lastPathComponent], 0.375)
    }

    func testARecoveredRecordingWithoutASidecarKeepsDelayZero() async throws {
        let mix = try stage("20260311_090000")

        let delays = await recoveredDelays()

        XCTAssertEqual(delays[mix.lastPathComponent], 0)
    }

    func testAnUnreadableSidecarKeepsDelayZero() async throws {
        let mix = try stage("20260311_090000")
        try Data("not json".utf8).write(to: XCTUnwrap(RecordingSidecar.recordingSidecarURL(besideMix: mix)))

        let delays = await recoveredDelays()

        XCTAssertEqual(delays[mix.lastPathComponent], 0)
    }

    func testAnOrphanNeverTakesAnotherStemsSidecar() async throws {
        let withSidecar = try stage("20260311_090000", delay: 0.375)
        let without = try stage("20260311_100000")
        // Beside the second mix under its name, but written for the first one.
        let foreign = try stage("20260311_110000", delay: 0.5, sidecarMix: withSidecar.lastPathComponent)

        let delays = await recoveredDelays()

        XCTAssertEqual(delays[withSidecar.lastPathComponent], 0.375)
        XCTAssertEqual(delays[without.lastPathComponent], 0)
        XCTAssertEqual(delays[foreign.lastPathComponent], 0, "a sidecar that names another mix is not this recording's")
    }
}
