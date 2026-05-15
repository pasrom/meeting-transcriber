@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class VoiceEnrollmentViewTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "VoiceEnrollmentViewTests")
        dbPath = tmpDir.appendingPathComponent("speakers.json")
    }

    // MARK: - Helpers

    private func makeView(
        matcher: SpeakerMatcher? = nil,
        initialStage: VoiceEnrollmentView.Stage = .pickFile,
        onClose: @escaping () -> Void = {},
    ) -> VoiceEnrollmentView {
        VoiceEnrollmentView(
            matcher: matcher ?? SpeakerMatcher(dbPath: dbPath),
            diarizerFactory: { MockDiarization() },
            onClose: onClose,
            initialStage: initialStage,
        )
    }

    private func makeNamingPayload(
        url: URL = URL(fileURLWithPath: "/tmp/voice-enrollment-test.wav"),
        diarization: DiarizationResult? = nil,
        knownNames: [String] = [],
    ) -> VoiceEnrollmentView.NamingPayload {
        let diar = diarization ?? DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_00"),
                .init(start: 5, end: 10, speaker: "SPEAKER_01"),
            ],
            speakingTimes: ["SPEAKER_00": 5, "SPEAKER_01": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_00": [1, 0, 0], "SPEAKER_01": [0, 1, 0]],
        )
        let data = PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: url.lastPathComponent,
            mapping: ["SPEAKER_00": "SPEAKER_00", "SPEAKER_01": "SPEAKER_01"],
            speakingTimes: diar.speakingTimes,
            embeddings: diar.embeddings ?? [:],
            audioPath: url,
            segments: diar.segments.map { seg in
                PipelineQueue.SpeakerNamingData.Segment(
                    start: seg.start, end: seg.end, speaker: seg.speaker,
                )
            },
            participants: [],
            isDualSource: false,
        )
        return VoiceEnrollmentView.NamingPayload(
            url: url,
            diarization: diar,
            namingData: data,
            knownNames: knownNames,
            speakerCount: Set(diar.segments.map(\.speaker)).count,
        )
    }

    // MARK: - Render: pickFile

    func testRendersInPickFileStage() throws {
        let view = makeView()
        XCTAssertNoThrow(try view.inspect())
    }

    func testRendersPickFileBodyWithBothPickerButtons() throws {
        let body = try makeView().inspect()
        XCTAssertNoThrow(try body.find(button: "Choose File…"))
        XCTAssertNoThrow(try body.find(button: "Browse Past Recordings…"))
        XCTAssertNoThrow(try body.find(text: "Add Voice from Recording"))
    }

    // MARK: - Render: diarizing

    func testRendersDiarizingBodyShowsFilename() throws {
        let url = URL(fileURLWithPath: "/tmp/standup.wav")
        let body = try makeView(initialStage: .diarizing(url)).inspect()
        let texts = body.findAll(ViewType.Text.self)
        let hasFilename = texts.contains { (try? $0.string())?.contains("standup.wav") == true }
        XCTAssertTrue(hasFilename, "Diarizing body should mention the file name")
    }

    // MARK: - Render: naming

    func testRendersNamingBodyShowsSpeakerCount() throws {
        let payload = makeNamingPayload()
        let body = try makeView(initialStage: .naming(payload)).inspect()
        let texts = body.findAll(ViewType.Text.self)
        let hasCount = texts.contains { (try? $0.string())?.contains("Found 2 speakers") == true }
        XCTAssertTrue(hasCount, "Naming body should show speaker count")
    }

    // MARK: - Render: done

    func testRendersDoneBodyWithMultipleSpeakers() throws {
        let body = try makeView(initialStage: .done(savedNames: ["Alice", "Bob"])).inspect()
        XCTAssertNoThrow(try body.find(text: "Enrolled 2 speakers"))
        XCTAssertNoThrow(try body.find(text: "Alice, Bob"))
        XCTAssertNoThrow(try body.find(button: "Done"))
    }

    func testRendersDoneBodySingularGrammar() throws {
        let body = try makeView(initialStage: .done(savedNames: ["Alice"])).inspect()
        XCTAssertNoThrow(try body.find(text: "Enrolled 1 speaker"))
    }

    func testRendersDoneBodyEmptySkipsNameList() throws {
        let body = try makeView(initialStage: .done(savedNames: [])).inspect()
        XCTAssertNoThrow(try body.find(text: "Enrolled 0 speakers"))
        let texts = body.findAll(ViewType.Text.self)
        let hasCommaList = texts.contains { (try? $0.string())?.contains(",") == true }
        XCTAssertFalse(hasCommaList, "Empty enrollment should not render a comma-separated list")
    }

    // MARK: - Render: error

    func testRendersErrorBodyShowsMessageAndButtons() throws {
        let body = try makeView(initialStage: .error("disk full")).inspect()
        XCTAssertNoThrow(try body.find(text: "Enrollment failed"))
        XCTAssertNoThrow(try body.find(text: "disk full"))
        XCTAssertNoThrow(try body.find(button: "Try Again"))
        XCTAssertNoThrow(try body.find(button: "Close"))
    }

    // MARK: - Button taps

    func testCancelButtonCallsOnClose() throws {
        var closed = false
        let body = try makeView { closed = true }.inspect()
        try body.find(button: "Cancel").tap()
        XCTAssertTrue(closed)
    }

    func testDoneButtonCallsOnClose() throws {
        var closed = false
        let body = try makeView(initialStage: .done(savedNames: ["Alice"])) { closed = true }
            .inspect()
        try body.find(button: "Done").tap()
        XCTAssertTrue(closed)
    }

    func testErrorCloseButtonCallsOnClose() throws {
        var closed = false
        let body = try makeView(initialStage: .error("oops")) { closed = true }.inspect()
        try body.find(button: "Close").tap()
        XCTAssertTrue(closed)
    }

    // MARK: - Inlined namingBody closure (covers the call-site switch on Outcome)

    func testNamingStageSkipButtonRunsInlinedClosure() throws {
        // Tapping Skip on the embedded SpeakerNamingView fires
        // VoiceEnrollmentView's inlined `onComplete` closure → executes the
        // switch on `VoiceEnrollmentLogic.Outcome`. Coverage is the goal here;
        // we can't observe the @State transition from outside the SwiftUI
        // render context.
        let view = makeView(initialStage: .naming(makeNamingPayload()))
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(button: "Skip").tap())
    }

    func testNamingStageRerunButtonRunsInlinedClosure() throws {
        // Same idea for the .rerun branch of the inlined switch — taps the
        // SpeakerNamingView's "Re-run" button which fires `onComplete(.rerun(N))`.
        let view = makeView(initialStage: .naming(makeNamingPayload()))
        let body = try view.inspect()
        let rerun = try body.find(viewWithAccessibilityIdentifier: "rerun-button")
        XCTAssertNoThrow(try rerun.button().tap())
    }

    // MARK: - VoiceEnrollmentLogic.handleNamingResult

    func testHandleNamingResultConfirmedPersistsSpeakersAndReturnsDoneStage() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let outcome = VoiceEnrollmentLogic.handleNamingResult(
            .confirmed(["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"]),
            payload: makeNamingPayload(),
            matcher: matcher,
        )
        XCTAssertEqual(Set(matcher.allSpeakerNames()), ["Alice", "Bob"])
        guard case let .stage(.done(savedNames)) = outcome else {
            XCTFail("Expected .stage(.done), got something else")
            return
        }
        XCTAssertEqual(savedNames, ["Alice", "Bob"])
    }

    func testHandleNamingResultConfirmedWithoutEmbeddingsReturnsErrorStage() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        // Without embeddings, updateDB has no per-label vector to attach;
        // the logic surfaces this as an error stage rather than silently
        // dropping the user's input.
        let diar = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_00")],
            speakingTimes: ["SPEAKER_00": 5],
            autoNames: [:],
            embeddings: nil,
        )
        let outcome = VoiceEnrollmentLogic.handleNamingResult(
            .confirmed(["SPEAKER_00": "Alice"]),
            payload: makeNamingPayload(diarization: diar),
            matcher: matcher,
        )
        XCTAssertTrue(matcher.allSpeakerNames().isEmpty)
        guard case .stage(.error) = outcome else {
            XCTFail("Expected .stage(.error), got something else")
            return
        }
    }

    func testHandleNamingResultSkippedReturnsDoneStageWithNoNames() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let outcome = VoiceEnrollmentLogic.handleNamingResult(
            .skipped, payload: makeNamingPayload(), matcher: matcher,
        )
        XCTAssertTrue(matcher.allSpeakerNames().isEmpty)
        guard case let .stage(.done(savedNames)) = outcome else {
            XCTFail("Expected .stage(.done), got something else")
            return
        }
        XCTAssertTrue(savedNames.isEmpty)
    }

    func testHandleNamingResultRerunForwardsURLAndSpeakerCount() {
        let url = URL(fileURLWithPath: "/tmp/rerun-target.wav")
        let outcome = VoiceEnrollmentLogic.handleNamingResult(
            .rerun(3),
            payload: makeNamingPayload(url: url),
            matcher: SpeakerMatcher(dbPath: dbPath),
        )
        guard case let .rerun(rerunURL, count) = outcome else {
            XCTFail("Expected .rerun, got something else")
            return
        }
        XCTAssertEqual(rerunURL, url)
        XCTAssertEqual(count, 3)
    }

    // MARK: - VoiceEnrollmentLogic.buildNamingPayload

    func testBuildNamingPayloadFallsBackToIdentityWhenMatcherEmpty() {
        let matcher = SpeakerMatcher(dbPath: dbPath) // empty DB → no auto-names
        let diar = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_00"),
                .init(start: 5, end: 10, speaker: "SPEAKER_01"),
            ],
            speakingTimes: ["SPEAKER_00": 5, "SPEAKER_01": 5],
            autoNames: [:],
            embeddings: nil,
        )
        let payload = VoiceEnrollmentLogic.buildNamingPayload(
            url: URL(fileURLWithPath: "/tmp/foo.wav"), diarization: diar, matcher: matcher,
        )
        XCTAssertEqual(payload.speakerCount, 2)
        XCTAssertEqual(payload.namingData.mapping["SPEAKER_00"], "SPEAKER_00")
        XCTAssertEqual(payload.namingData.mapping["SPEAKER_01"], "SPEAKER_01")
        XCTAssertTrue(payload.knownNames.isEmpty)
    }

    func testBuildNamingPayloadIncludesKnownSpeakerNames() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([
            StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Bob", embeddings: [[0, 1, 0]]),
        ])
        let diar = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_00")],
            speakingTimes: ["SPEAKER_00": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_00": [1, 0, 0]],
        )
        let payload = VoiceEnrollmentLogic.buildNamingPayload(
            url: URL(fileURLWithPath: "/tmp/bar.wav"), diarization: diar, matcher: matcher,
        )
        XCTAssertEqual(Set(payload.knownNames), ["Alice", "Bob"])
    }

    func testBuildNamingPayloadDedupsSpeakerCountFromSegments() {
        // Three segments but only two distinct speakers — speakerCount must be 2.
        let diar = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_00"),
                .init(start: 5, end: 10, speaker: "SPEAKER_01"),
                .init(start: 10, end: 15, speaker: "SPEAKER_00"),
            ],
            speakingTimes: ["SPEAKER_00": 10, "SPEAKER_01": 5],
            autoNames: [:],
            embeddings: nil,
        )
        let payload = VoiceEnrollmentLogic.buildNamingPayload(
            url: URL(fileURLWithPath: "/tmp/baz.wav"),
            diarization: diar,
            matcher: SpeakerMatcher(dbPath: dbPath),
        )
        XCTAssertEqual(payload.speakerCount, 2)
    }

    // MARK: - KnownVoicesView integration (this view is what hosts VoiceEnrollmentView)

    func testKnownVoicesViewShowsEnrollButtonWhenFactoryProvided() throws {
        let view = KnownVoicesView(
            matcher: SpeakerMatcher(dbPath: dbPath),
            diarizerFactory: { MockDiarization() } as (() -> any DiarizationProvider),
        )
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(button: "Add from Recording…"))
    }

    func testKnownVoicesViewHidesEnrollButtonWhenNoFactory() throws {
        let view = KnownVoicesView(matcher: SpeakerMatcher(dbPath: dbPath))
        let inspected = try view.inspect()
        XCTAssertThrowsError(try inspected.find(button: "Add from Recording…"))
    }

    func testKnownVoicesViewDisablesEnrollButtonWhenNamingDialogActive() throws {
        let view = KnownVoicesView(
            matcher: SpeakerMatcher(dbPath: dbPath),
            diarizerFactory: { MockDiarization() },
            namingDialogActive: true,
        )
        let inspected = try view.inspect()
        let button = try inspected.find(button: "Add from Recording…")
        XCTAssertTrue(button.isDisabled())
    }

    func testKnownVoicesViewShowsBusyHintWhenPipelineBusy() throws {
        let view = KnownVoicesView(
            matcher: SpeakerMatcher(dbPath: dbPath),
            diarizerFactory: { MockDiarization() },
            pipelineBusy: true,
        )
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Pipeline busy — diarization may be slower."))
    }
}
