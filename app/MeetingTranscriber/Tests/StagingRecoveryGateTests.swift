@testable import MeetingTranscriber
import XCTest

/// Staging recoveries in this process run one at a time, and each judges file
/// ages from when it was requested.
///
/// Two recoveries of one crashed stem that overlap can end with a
/// microphone-only mix over the complete one: the second finds the stem not yet
/// mixed, the first mixes it and consumes the raw app temp, and the second
/// rebuilds from the microphone track alone. Every queue rebuild starts a
/// recovery, so the gate makes a recovery wait for the one already running.
@MainActor
final class StagingRecoveryGateTests: XCTestCase {
    private let stem = "20260311_140000"

    private func makeCrashedStem(in dir: URL, backdated: Bool = true) throws {
        let appTmp = dir.appendingPathComponent(stem + RecordingFileSuffix.appRaw)
        try writeRawFloat32([Float](repeating: 0.3, count: 16000 * 2), to: appTmp)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        try Data().write(to: DualSourceRecorder.inProgressMarker(stem: stem, in: dir))
        if backdated { try backdate([appTmp, micWav]) }
    }

    private func mixExists(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(stem + RecordingFileSuffix.mix).path)
    }

    /// Holds the gate the way a recovery re-mixing a long recording does, for
    /// as long as the test wants.
    private func holdTheGate(on _: URL) async -> (release: DispatchSemaphore, holder: Task<Void, Never>) {
        let release = DispatchSemaphore(value: 0)
        let holding = expectation(description: "the first recovery holds the gate")
        let holder = Task.detached {
            await StagingRecoveryGate.run {
                holding.fulfill()
                release.wait()
            }
        }
        await fulfillment(of: [holding], timeout: 5)
        return (release, holder)
    }

    /// The recovery production runs (`StagingRecoveryGate.recover`) waits for
    /// the one already running before it scans.
    func testARecoveryWaitsForTheOneRunningInThisProcess() async throws {
        let dir = try makeTempDirectory(prefix: "staging_gate")
        try makeCrashedStem(in: dir)
        let (release, holder) = await holdTheGate(on: dir)

        let second = Task.detached { await StagingRecoveryGate.recover(in: dir) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(mixExists(in: dir), "the second recovery ran while the first held the gate")

        release.signal()
        await holder.value
        await second.value
        XCTAssertTrue(mixExists(in: dir), "the second recovery never ran")
    }

    /// A recovery that waited behind another judges ages from when it was
    /// requested, not from when it got to run. A recording that began while
    /// it waited and then stopped writing (a channel that stalled) is older
    /// than the age guard by then, and would be re-mixed and its raw temp
    /// deleted underneath its writer.
    func testAWaitingRecoveryLeavesARecordingThatBeganAfterTheRequestAlone() async throws {
        let dir = try makeTempDirectory(prefix: "staging_gate_cutoff")
        let (release, holder) = await holdTheGate(on: dir)
        let requestedAt = Date()
        let recovery = Task.detached {
            await StagingRecoveryGate.recover(in: dir, requestedAt: requestedAt, minAge: 0.2)
        }
        // The recording begins after the request and stalls at once.
        try makeCrashedStem(in: dir, backdated: false)
        try await Task.sleep(for: .milliseconds(600))

        release.signal()
        await holder.value
        await recovery.value

        XCTAssertFalse(mixExists(in: dir), "a recording that began after the request was re-mixed as a crash")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(stem + RecordingFileSuffix.appRaw).path),
            "the live recording's raw temp was deleted",
        )
    }
}
