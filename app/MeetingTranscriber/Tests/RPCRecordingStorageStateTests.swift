#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The `/state.recordingStorage` object a lane waits on: the codec the
    /// probe found and whether the compactor still owes or is doing work.
    @MainActor
    final class RPCRecordingStorageStateTests: XCTestCase {
        func testTheSnapshotFollowsTheCompactor() throws {
            let state = try makeRPCTestState()
            let compaction = state.pipeline.recordingCompaction
            compaction.codecStatus = .unavailable(reason: "notNativeFLAC")
            let root = URL(fileURLWithPath: "/rpc-storage/Output")
            let jobID = UUID()
            compaction.registry.register(
                jobID: jobID, paths: [root.appendingPathComponent("recordings/m_mix.wav")], root: root, recordedAt: Date(),
            )
            compaction.registry.markAwaiting(.flac, jobID: jobID, root: root)

            let storage = state.rpcStateSnapshot().recordingStorage

            XCTAssertEqual(storage.codec, "none")
            XCTAssertEqual(storage.codecUnavailableReason, "notNativeFLAC")
            XCTAssertEqual(storage.awaitingCompaction, 1)
            XCTAssertFalse(storage.compacting)
        }
    }
#endif
