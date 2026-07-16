#if !APPSTORE
    import AppKit
    @testable import MeetingTranscriber
    import XCTest

    /// Covers the `windows` field of the RPC `/state` snapshot: it projects each
    /// named scene window's pinning-relevant properties (level / collection
    /// behavior / visibility) so the e2e-app naming-confirm lane can assert the
    /// speaker-naming window is pinned (issue #504) without screenshot OCR.
    ///
    /// The load-bearing property is `floating` (+ the Space flags): an un-pinned
    /// `NSWindow` stays *visible* on deactivation too, so a visibility-only check
    /// would be vacuous. Reverting `NamingWindowPolicy` flips `floating` to false
    /// here, which is what turns the lane red.
    @MainActor
    final class RPCWindowSnapshotTests: XCTestCase {
        private func makeWindow() -> NSWindow {
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled], backing: .buffered, defer: true,
            )
        }

        func testWindowInfoReflectsPinnedState() {
            let window = makeWindow()
            NamingWindowPolicy.apply(to: window)
            let info = RPCStateSnapshot.WindowInfo(window: window, id: "speaker-naming")
            XCTAssertEqual(info.id, "speaker-naming")
            XCTAssertTrue(info.floating)
            XCTAssertTrue(info.canJoinAllSpaces)
            XCTAssertTrue(info.fullScreenAuxiliary)
        }

        /// Non-vacuous guard: an un-pinned window reports `floating == false`,
        /// so a reverted `NamingWindowPolicy` would flip the lane assertion red.
        func testWindowInfoReportsUnpinnedWindowAsNotFloating() {
            let window = makeWindow()
            let info = RPCStateSnapshot.WindowInfo(window: window, id: "settings")
            XCTAssertFalse(info.floating)
            XCTAssertFalse(info.canJoinAllSpaces)
            XCTAssertFalse(info.fullScreenAuxiliary)
        }

        /// The exact wire shape the e2e `jq` filter reads.
        func testWindowsSerialiseIntoSnapshotJSON() throws {
            let info = RPCStateSnapshot.WindowInfo(
                id: "speaker-naming",
                isVisible: true,
                floating: true,
                canJoinAllSpaces: true,
                fullScreenAuxiliary: true,
            )
            XCTAssertTrue(info.isVisible)
            let snapshot = RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: false,
                    activeJobCount: 0,
                    waitingJobCount: 0,
                    pendingNamingJobCount: 0,
                ),
                speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
                pendingNamingJobs: [],
                windows: [info],
            )
            let json = try XCTUnwrap(String(data: snapshot.jsonData(), encoding: .utf8))
            XCTAssertTrue(json.contains("\"id\" : \"speaker-naming\""), json)
            XCTAssertTrue(json.contains("\"floating\" : true"), json)
            XCTAssertTrue(json.contains("\"isVisible\" : true"), json)
        }
    }
#endif
