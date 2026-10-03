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

        // A mic track whose writer was killed: a RIFF header claiming zero bytes
        // of payload, which is what `repairUnfinalized` exists to correct.
        let unfinalized = staging.appendingPathComponent("20260101_1200_mic.wav")
        try unfinalizedWav(frames: 1600).write(to: unfinalized)
        // Older than the repair's minimum age, so it counts as abandoned rather
        // than as a recording still being written.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: unfinalized.path,
        )
        let before = try XCTUnwrap(try? Data(contentsOf: unfinalized).count)

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
        for _ in 0 ..< 200 where !repaired {
            try? await Task.sleep(for: .milliseconds(10))
            let header = try? Data(contentsOf: unfinalized)
            repaired = (header?.count ?? 0) == before && readDataChunkSize(header) > 0
        }
        XCTAssertTrue(
            repaired,
            "the staging recovery did not touch the queue's staging folder, so it was working somewhere else",
        )
    }

    /// A 16 kHz mono WAV whose `data` chunk size is still zero, the state a
    /// recording left behind when its writer died before finalising.
    private func unfinalizedWav(frames: Int) -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(contentsOf: withUnsafeBytes(of: UInt32(36 + frames * 2).littleEndian) { Array($0) })
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        d.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        d.append(contentsOf: Array("data".utf8))
        d.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        d.append(Data(count: frames * 2))
        return d
    }

    private func readDataChunkSize(_ data: Data?) -> UInt32 {
        guard let data, data.count >= 44 else { return 0 }
        return data.subdata(in: 40 ..< 44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }
}
