@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class VoiceEnrollmentViewTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceEnrollmentViewTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        dbPath = tmpDir.appendingPathComponent("speakers.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
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
            diarizerFactory: { MockDiarization() } as (() -> DiarizationProvider),
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
        XCTAssertTrue(try button.isDisabled())
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
