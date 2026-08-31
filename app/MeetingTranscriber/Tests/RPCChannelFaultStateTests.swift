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
        }
    }
#endif
