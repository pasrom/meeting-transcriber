#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Covers the menu-bar `badge` field exposed in the RPC `/state` snapshot:
    /// the `BadgeKind` -> wire-string contract, that the snapshot builder wires it
    /// from `AppState.currentBadge` (not a hardcode), and that it serialises into
    /// the snapshot JSON. Lets a driver script assert the menu-bar state
    /// deterministically instead of pixel-matching a `/screenshot`.
    @MainActor
    final class RPCBadgeStateTests: XCTestCase {
        // MARK: - BadgeKind wire contract

        func testBadgeKindRawValueMapsEveryCase() {
            // Exact wire strings — a driver script asserts against these, so a
            // rename/reorder is a breaking contract change that must be deliberate.
            XCTAssertEqual(BadgeKind.inactive.rawValue, "inactive")
            XCTAssertEqual(BadgeKind.recording.rawValue, "recording")
            XCTAssertEqual(BadgeKind.transcribing.rawValue, "transcribing")
            XCTAssertEqual(BadgeKind.diarizing.rawValue, "diarizing")
            XCTAssertEqual(BadgeKind.processing.rawValue, "processing")
            XCTAssertEqual(BadgeKind.userAction.rawValue, "userAction")
            XCTAssertEqual(BadgeKind.done.rawValue, "done")
            XCTAssertEqual(BadgeKind.error.rawValue, "error")
            XCTAssertEqual(BadgeKind.updateAvailable.rawValue, "updateAvailable")
            // Guard: every case is pinned above — a newly-added case fails this
            // count and forces the author to add its wire string here.
            XCTAssertEqual(BadgeKind.allCases.count, 9)
        }

        // MARK: - Wiring: snapshot.badge follows currentBadge (non-vacuous)

        func testSnapshotBadgeReflectsCurrentBadge() throws {
            let state = makeRPCTestState()

            // Fresh idle app -> inactive, on both the computed property and the wire.
            XCTAssertEqual(state.currentBadge, .inactive)
            XCTAssertEqual(state.rpcStateSnapshot().badge, .inactive)

            // Drive currentBadge to a NON-inactive value; the snapshot must follow.
            // A hardcoded `.inactive` in the builder would fail this.
            let url = try XCTUnwrap(URL(string: "https://example.com"))
            state.updateChecker.availableUpdate = ReleaseInfo(
                tagName: "v9.9.9",
                name: "Test Release",
                prerelease: false,
                htmlURL: url,
                dmgURL: nil,
            )
            XCTAssertEqual(state.currentBadge, .updateAvailable)
            // Bind once — every rpcStateSnapshot() does a real speakers.json read.
            let snap = state.rpcStateSnapshot()
            XCTAssertEqual(snap.badge, .updateAvailable)
            XCTAssertEqual(snap.badge, state.currentBadge)
        }

        // MARK: - Serialisation

        func testBadgeSerialisesIntoSnapshotJSON() throws {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: false,
                    activeJobCount: 0,
                    waitingJobCount: 0,
                    pendingNamingJobCount: 0,
                ),
                speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
                pendingNamingJobs: [],
                badge: .recording,
            )
            let json = try XCTUnwrap(String(data: snapshot.jsonData(), encoding: .utf8))
            // jsonData() is pretty-printed with sorted keys -> `"key" : "value"`;
            // a String-raw Codable enum encodes to its raw value.
            XCTAssertTrue(json.contains("\"badge\" : \"recording\""), json)
        }
    }
#endif
