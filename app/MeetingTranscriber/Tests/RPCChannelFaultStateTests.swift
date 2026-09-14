#if !APPSTORE
    import AudioTapLib
    @testable import MeetingTranscriber
    import XCTest

    /// Covers the capture-fault fields of the `/state` `channelHealth` object.
    ///
    /// The notification about a dead capture channel is gone the moment it is
    /// posted, and the menu-bar tint says only "quiet", not "broken". This is
    /// the surface a driver script polls and a field diagnosis reads back, and
    /// it carries the evidence next to the verdict: a channel called dead after
    /// ten seconds of silence and one called dead after ten minutes are
    /// different bugs.
    @MainActor
    final class RPCChannelFaultStateTests: XCTestCase {
        private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        func testAHealthyRecordingReportsNoFault() {
            let state = makeRPCTestState()
            let health = state.rpcStateSnapshot().channelHealth
            XCTAssertNil(health.micFault)
            XCTAssertNil(health.appFault)
            XCTAssertFalse(health.appDigitalSilence)
        }

        func testRollingDigitalSilenceReachesTheSnapshotWithoutReplacingNativeEvidence() throws {
            let state = makeRPCTestState()
            let recorder = MockRecorder()
            recorder.micLevelDBFS = -80
            recorder.appLevelDBFS = -100
            recorder.appSignalAges = ChannelSignalAges(secondsSinceLastBuffer: 0.1, secondsSinceLastEnergy: 2)
            recorder.micSignalAges = ChannelSignalAges(secondsSinceLastBuffer: 0.2, secondsSinceLastEnergy: 3)
            recorder.appCaptureDigitallySilent = true
            state.channelHealth.simulateStartForTests()

            state.channelHealth.applyTick(recorder: recorder, now: t0)

            let health = state.rpcStateSnapshot().channelHealth
            XCTAssertTrue(health.appDigitalSilence)
            XCTAssertEqual(health.appFault, "digitalSilence")
            XCTAssertNil(health.micFault)
            XCTAssertEqual(health.appSecondsSinceLastBuffer, 0.1)
            XCTAssertEqual(health.appSecondsSinceLastEnergy, 2)
            XCTAssertEqual(health.micSecondsSinceLastBuffer, 0.2)
            XCTAssertEqual(health.micSecondsSinceLastEnergy, 3)
            XCTAssertEqual(health.appLevelDBFS, -100)
            XCTAssertEqual(health.micLevelDBFS, -80)

            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(health)) as? [String: Any],
            )
            XCTAssertEqual(json["appDigitalSilence"] as? Bool, true)
            XCTAssertEqual(json["appFault"] as? String, "digitalSilence")

            recorder.appCaptureDigitallySilent = false
            state.channelHealth.applyTick(recorder: recorder, now: t0.addingTimeInterval(1))
            let recovered = state.rpcStateSnapshot().channelHealth
            XCTAssertFalse(recovered.appDigitalSilence)
            XCTAssertEqual(recovered.appFault, "digitalSilence", "the fault is history, the Boolean is live")

            state.channelHealth.stop()
            let stopped = state.rpcStateSnapshot().channelHealth
            XCTAssertFalse(stopped.appDigitalSilence)
            XCTAssertNil(stopped.appFault)
            XCTAssertNil(stopped.appSecondsSinceLastEnergy)
        }

        func testTheSnapshotFollowsTheReportedFault() throws {
            let state = makeRPCTestState()
            let recorder = MockRecorder()
            recorder.appLevelDBFS = -20
            recorder.micLevelDBFS = -120
            recorder.micSignalAges = ChannelHealthHarness.stoppedDelivering
            state.channelHealth.simulateStartForTests()

            state.channelHealth.applyTick(recorder: recorder, now: t0)
            _ = state.channelHealth.applyTick(recorder: recorder, now: t0.addingTimeInterval(300))

            // A hardcoded nil in the builder would fail this.
            let health = state.rpcStateSnapshot().channelHealth
            XCTAssertEqual(health.micFault, "noBuffers")
            XCTAssertNil(health.appFault)
            XCTAssertEqual(try XCTUnwrap(health.micSecondsSinceLastBuffer), 600, accuracy: 0.001)
        }

        func testTheSnapshotDistinguishesTheTwoFaults() {
            // The two call for different fixes, so one bit would not do.
            let state = makeRPCTestState()
            let recorder = MockRecorder()
            recorder.appLevelDBFS = -20
            recorder.micLevelDBFS = -120
            recorder.micSignalAges = ChannelHealthHarness.deliveringSilence
            state.channelHealth.simulateStartForTests()

            state.channelHealth.applyTick(recorder: recorder, now: t0)
            _ = state.channelHealth.applyTick(recorder: recorder, now: t0.addingTimeInterval(300))

            XCTAssertEqual(state.rpcStateSnapshot().channelHealth.micFault, "digitalSilence")
        }

        func testTheSnapshotCarriesTheLevelsTheVerdictWasReadFrom() throws {
            // The two thresholds that decide the menu-bar tint are levels, and
            // nothing exposed them. Diagnosing why a channel did or did not
            // latch meant inferring the level from the flag it produced, which
            // is backwards and took three runs to settle on real hardware.
            // Distinct values per channel, so a snapshot wired to the wrong one
            // fails instead of coinciding.
            let state = makeRPCTestState()
            let recorder = MockRecorder()
            recorder.micLevelDBFS = -72
            recorder.appLevelDBFS = -18
            state.channelHealth.simulateStartForTests()

            state.channelHealth.applyTick(recorder: recorder, now: t0)

            let health = state.rpcStateSnapshot().channelHealth
            XCTAssertEqual(try XCTUnwrap(health.micLevelDBFS), -72, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(health.appLevelDBFS), -18, accuracy: 0.001)
        }

        func testTheLevelsAreAbsentBeforeAnyTick() {
            let state = makeRPCTestState()
            let health = state.rpcStateSnapshot().channelHealth
            XCTAssertNil(health.micLevelDBFS)
            XCTAssertNil(health.appLevelDBFS)
        }

        func testTheInactiveSnapshotCarriesNoFault() {
            let inactive = RPCStateSnapshot.ChannelHealth.inactive
            XCTAssertNil(inactive.micFault)
            XCTAssertNil(inactive.appFault)
            XCTAssertNil(inactive.micSecondsSinceLastBuffer)
            XCTAssertFalse(inactive.appDigitalSilence)
        }
    }
#endif
