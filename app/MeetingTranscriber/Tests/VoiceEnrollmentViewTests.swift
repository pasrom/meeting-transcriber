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

    func testRendersInPickFileStage() throws {
        let view = VoiceEnrollmentView(
            matcher: SpeakerMatcher(dbPath: dbPath),
            diarizerFactory: { MockDiarization() },
            onClose: {},
        )
        XCTAssertNoThrow(try view.inspect())
    }

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
