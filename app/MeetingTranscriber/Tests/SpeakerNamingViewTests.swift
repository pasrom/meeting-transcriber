import ViewInspector
import XCTest

@testable import MeetingTranscriber

final class SpeakerNamingViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeSpeaker(
        label: String = "SPEAKER_00",
        autoName: String? = nil,
        confidence: Double = 0.0,
        time: Double = 60.0
    ) -> SpeakerInfo {
        SpeakerInfo(
            label: label,
            autoName: autoName,
            confidence: confidence,
            speakingTimeSeconds: time,
            sampleFile: "\(label).wav"
        )
    }

    private func makeRequest(
        title: String = "Standup",
        speakers: [SpeakerInfo]? = nil
    ) -> SpeakerRequest {
        SpeakerRequest(
            version: 1,
            timestamp: "2024-01-01T00:00:00",
            meetingTitle: title,
            audioSamplesDir: "/tmp/samples",
            speakers: speakers ?? [makeSpeaker()]
        )
    }

    // MARK: - Tests

    func testHeaderShowsMeetingTitle() throws {
        let sut = SpeakerNamingView(
            request: makeRequest(title: "Planning"),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        // Header uses string interpolation (LocalizedStringKey); extract all texts and check
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("Planning") == true }
        XCTAssertTrue(found, "Meeting title 'Planning' not found in any Text view")
    }

    func testRendersAllSpeakerRows() throws {
        let speakers = [
            makeSpeaker(label: "SPEAKER_00"),
            makeSpeaker(label: "SPEAKER_01"),
            makeSpeaker(label: "SPEAKER_02"),
        ]
        let sut = SpeakerNamingView(
            request: makeRequest(speakers: speakers),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        let groups = body.findAll(ViewType.GroupBox.self)
        XCTAssertEqual(groups.count, 3)
    }

    func testShowsAutoNameWhenPresent() throws {
        let speaker = makeSpeaker(label: "SPEAKER_00", autoName: "Roman", confidence: 0.85)
        let sut = SpeakerNamingView(
            request: makeRequest(speakers: [speaker]),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        // The view renders "Auto: Roman (85%)" via string interpolation
        XCTAssertNoThrow(try body.find(text: "Auto: Roman (85%)"))
    }

    func testShowsUnknownWhenNoAutoName() throws {
        let speaker = makeSpeaker(label: "SPEAKER_00", autoName: nil)
        let sut = SpeakerNamingView(
            request: makeRequest(speakers: [speaker]),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Unknown"))
    }

    func testConfirmAndSkipButtonsExist() throws {
        let sut = SpeakerNamingView(
            request: makeRequest(),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Confirm"))
        XCTAssertNoThrow(try body.find(button: "Skip"))
    }
}
