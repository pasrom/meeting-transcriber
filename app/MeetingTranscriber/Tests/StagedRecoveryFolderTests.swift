@testable import MeetingTranscriber
import XCTest

/// The staging recovery repairs WAV headers, re-mixes crashed recordings and
/// deletes temporary files. All three write, so the folder it works in has to be
/// the one the queue was built with and never the process-wide default: a
/// controller built against a temp staging folder reaching into the real
/// recordings folder is the hazard that injecting the folder exists to remove.
///
/// Only the repaired-header half is asserted, because it is the one with a
/// visible result on a file this test created. There is deliberately no probe
/// that reverts the fix: that one would scan and rewrite the real recordings
/// folder.
@MainActor
final class StagedRecoveryFolderTests: XCTestCase {
    func testTheStagedRecoveryWorksInTheQueuesStagingFolder() async throws {
        let staging = try makeTempDirectory(prefix: "StagedRecoveryStaging")
        let output = try makeTempDirectory(prefix: "StagedRecoveryOutput")

        // A mic track whose writer was killed, built from a real WAV the app
        // wrote and then left unfinalized and aged, so the repair is pinned
        // against the file shape it actually meets instead of an invented one.
        let unfinalized = staging.appendingPathComponent("20260101_1200_mic.wav")
        try writeUnfinalizedWav(at: unfinalized)
        XCTAssertEqual(try dataChunkSize(at: unfinalized), 0, "test premise: the header starts unfinalized")

        let queue = try PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: output,
            logDir: makeTempDirectory(prefix: "StagedRecoveryLog"),
            stagingDir: staging,
        )
        let recover = try XCTUnwrap(PipelineController.QueueEnvironment.production.recoverStagedRecordings)
        recover(queue)

        var repaired = false
        let deadline = ContinuousClock.now + .seconds(5)
        while !repaired, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            repaired = ((try? dataChunkSize(at: unfinalized)) ?? 0) > 0
        }
        XCTAssertTrue(
            repaired,
            "the staging recovery did not touch the queue's staging folder, so it was working somewhere else",
        )
    }
}
