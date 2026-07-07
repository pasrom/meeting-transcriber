#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Covers the update-checker `updateStatus` sub-object exposed in the RPC
    /// `/state` snapshot: that the snapshot builder wires it from `AppState.updateChecker`
    /// (not a hardcode), and that it serialises. Lets a driver script assert the
    /// update-check flow (found version, in-flight check, error) that the `badge`
    /// only summarises as the boolean `.updateAvailable`.
    @MainActor
    final class RPCUpdateStatusTests: XCTestCase {
        // MARK: - Empty default

        func testEmptyUpdatesReadsAsNoUpdate() {
            let empty = RPCStateSnapshot.UpdateStatus.empty
            XCTAssertFalse(empty.available)
            XCTAssertNil(empty.availableVersion)
            XCTAssertFalse(empty.isPrerelease)
            XCTAssertFalse(empty.isChecking)
            XCTAssertNil(empty.lastError)
        }

        // MARK: - Wiring: snapshot.updateStatus follows updateChecker (non-vacuous)

        func testSnapshotUpdatesReflectAvailableUpdate() throws {
            let state = makeState()

            // Fresh app: no update, not checking, no error.
            let idle = state.rpcStateSnapshot().updateStatus
            XCTAssertFalse(idle.available)
            XCTAssertNil(idle.availableVersion)
            XCTAssertFalse(idle.isChecking)

            // Drive the update-checker; the snapshot must follow. A hardcoded
            // `.empty` in the builder would fail these.
            let url = try XCTUnwrap(URL(string: "https://example.com"))
            state.updateChecker.availableUpdate = ReleaseInfo(
                tagName: "v9.9.9",
                name: "Test Release",
                prerelease: true,
                htmlURL: url,
                dmgURL: nil,
            )
            state.updateChecker.isChecking = true
            state.updateChecker.lastError = "network down"

            let snap = state.rpcStateSnapshot().updateStatus
            XCTAssertTrue(snap.available)
            XCTAssertEqual(snap.availableVersion, "v9.9.9")
            XCTAssertTrue(snap.isPrerelease)
            XCTAssertTrue(snap.isChecking)
            XCTAssertEqual(snap.lastError, "network down")
        }

        // MARK: - Serialisation

        func testUpdatesSerialiseIntoSnapshotJSON() throws {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: false,
                    activeJobCount: 0,
                    waitingJobCount: 0,
                    pendingNamingJobCount: 0,
                ),
                speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
                pendingNamingJobs: [],
                updateStatus: .init(
                    available: true,
                    availableVersion: "v1.2.3",
                    isPrerelease: false,
                    isChecking: false,
                    lastError: nil,
                ),
            )
            let json = try XCTUnwrap(String(data: snapshot.jsonData(), encoding: .utf8))
            // jsonData() is pretty-printed with sorted keys -> `"key" : value`.
            XCTAssertTrue(json.contains("\"updateStatus\""), json)
            XCTAssertTrue(json.contains("\"available\" : true"), json)
            XCTAssertTrue(json.contains("\"availableVersion\" : \"v1.2.3\""), json)
        }

        // MARK: - Helpers

        private func makeState() -> AppState {
            let suite = "RPCUpdateStatusTests-\(getpid())-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                fatalError("Could not create test UserDefaults suite")
            }
            // Per-call unique volatile suite — remove it after the test so repeated
            // runs don't accumulate orphaned preference domains. Capture only the
            // Sendable suite name.
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            return AppState(settings: AppSettings(defaults: defaults))
        }
    }
#endif
