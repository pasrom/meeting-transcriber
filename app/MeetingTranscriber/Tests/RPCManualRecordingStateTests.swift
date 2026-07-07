#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Covers the `isManualRecording` flag exposed in the RPC `/state` snapshot:
    /// that the snapshot builder wires it from `AppState.isManualRecording` (not a
    /// hardcode), and that it serialises. `watchState` reads "recording" for both
    /// auto-detected and manual recordings, so this is the only wire signal that
    /// distinguishes the manual (app-picker) path.
    @MainActor
    final class RPCManualRecordingStateTests: XCTestCase {
        // MARK: - Wiring: snapshot.isManualRecording follows AppState (non-vacuous)

        func testSnapshotReflectsManualRecording() async throws {
            let state = makeRPCTestState()

            // Fresh app: no watch loop → not a manual recording.
            XCTAssertFalse(state.isManualRecording)
            XCTAssertFalse(state.rpcStateSnapshot().isManualRecording)

            // Start a manual recording via the mock-backed test WatchLoop; the
            // snapshot must follow. A hardcoded `false` in the builder fails this.
            let (loop, _) = makeTestWatchLoop()
            state.watching.watchLoop = loop
            try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")
            defer { loop.stop() }

            XCTAssertTrue(state.isManualRecording)
            XCTAssertTrue(state.rpcStateSnapshot().isManualRecording)
        }

        // MARK: - Serialisation

        func testIsManualRecordingSerialisesIntoSnapshotJSON() throws {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: false,
                    activeJobCount: 0,
                    waitingJobCount: 0,
                    pendingNamingJobCount: 0,
                ),
                speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
                pendingNamingJobs: [],
                isManualRecording: true,
            )
            let json = try XCTUnwrap(String(data: snapshot.jsonData(), encoding: .utf8))
            // jsonData() is pretty-printed with sorted keys -> `"key" : value`.
            XCTAssertTrue(json.contains("\"isManualRecording\" : true"), json)
        }
    }
#endif
