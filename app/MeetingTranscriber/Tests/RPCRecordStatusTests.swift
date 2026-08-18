#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The `/v1/record` status projection: which recording it calls its own,
    /// which it calls somebody else's, and the two switches a client needs in
    /// order to explain a 412 it just received.
    @MainActor
    final class RPCRecordStatusTests: XCTestCase {
        func testAMicrophoneRecordingIsThisEndpointsRecording() async throws {
            let state = makeRPCTestState()
            XCTAssertFalse(state.recordStatusDTO().recording, "precondition: nothing is recording")

            let (loop, _) = makeTestWatchLoop()
            state.watching.watchLoop = loop
            try await loop.startMicrophoneRecording()
            defer { loop.stop() }

            let dto = state.recordStatusDTO()
            XCTAssertTrue(dto.recording)
            XCTAssertFalse(dto.otherRecordingActive)
            XCTAssertEqual(dto.state, "recording")
        }

        /// The narrowing that keeps a client from stopping a meeting it never
        /// started: an app recording is reported, but not as this endpoint's.
        func testAnAppRecordingIsReportedAsSomebodyElses() async throws {
            let state = makeRPCTestState()
            let (loop, _) = makeTestWatchLoop()
            state.watching.watchLoop = loop
            try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")
            defer { loop.stop() }

            let dto = state.recordStatusDTO()
            XCTAssertFalse(dto.recording, "an app recording is not a microphone recording")
            XCTAssertTrue(dto.otherRecordingActive, "but a client has to be told something holds the loop")
        }

        /// `badge` is the field a physical key renders, and the only one no test
        /// read off a real projection: hardcoding it to `inactive` left the suite
        /// green while the key froze on the wrong glyph mid-recording.
        func testBadgeFollowsTheLiveBadge() async throws {
            let state = makeRPCTestState()
            let (loop, _) = makeTestWatchLoop()
            state.watching.watchLoop = loop
            try await loop.startMicrophoneRecording()
            defer { loop.stop() }

            XCTAssertEqual(state.recordStatusDTO().badge, state.currentBadge.rawValue)
            XCTAssertEqual(state.recordStatusDTO().badge, "recording")
        }

        /// The wire shape itself, which every other test misses by encoding and
        /// decoding the same type: a renamed key round-trips perfectly and breaks
        /// every documented client. Also pins the omit-don't-null convention the
        /// docs promise for `state`.
        func testTheWireShapeMatchesWhatTheDocsPromise() throws {
            let dto = RecordStatusDTO.notRecording

            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any],
            )

            XCTAssertEqual(
                Set(object.keys),
                ["recording", "startPending", "badge", "otherRecordingActive", "noMic", "microphoneHealthy"],
                "these key names are the published contract",
            )
            XCTAssertNil(object["state"], "a nil value is omitted, not sent as null")
        }

        /// The window a polling key would otherwise read as plain idle. Narrow
        /// on purpose: a *running* app recording is not a pending microphone
        /// start, and reporting it as one would have a key wait for something
        /// that is never going to become its recording.
        func testOnlyAnInFlightStartCountsAsPending() async throws {
            let state = makeRPCTestState()
            XCTAssertFalse(state.recordStatusDTO().startPending, "nothing in flight")

            let (loop, _) = makeTestWatchLoop()
            state.watching.watchLoop = loop
            try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")
            defer { loop.stop() }

            let dto = state.recordStatusDTO()
            XCTAssertFalse(dto.startPending, "a running app recording is not a pending start")
            XCTAssertTrue(dto.otherRecordingActive, "it is reported here instead")
        }

        func testTheNoMicrophoneSettingIsReported() {
            let state = makeRPCTestState()
            XCTAssertFalse(state.recordStatusDTO().noMic)

            state.settings.noMic = true

            XCTAssertTrue(state.recordStatusDTO().noMic, "a client needs this to explain the refusal it just got")
        }

        /// Scoped to the microphone, and asked through the same
        /// `recordingBlockers` the gate uses. A denied Screen Recording grant
        /// blocks no microphone recording, so reporting it here would describe
        /// the endpoint as broken on exactly the machines where it is the
        /// capture path that still works.
        func testOnlyAMicrophoneProblemMakesTheStatusUnhealthy() {
            let state = makeRPCTestState()
            XCTAssertTrue(state.recordStatusDTO().microphoneHealthy, "an unprobed check is not a problem")

            state.permissions.handle(HealthCheckResult(screenRecording: .denied, microphone: .healthy))
            XCTAssertTrue(state.recordStatusDTO().microphoneHealthy)

            state.permissions.handle(HealthCheckResult(screenRecording: .healthy, microphone: .broken))
            XCTAssertFalse(state.recordStatusDTO().microphoneHealthy, "allowed-but-not-working is a problem too")
        }
    }
#endif
