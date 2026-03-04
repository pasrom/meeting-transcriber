import ViewInspector
import XCTest

@testable import MeetingTranscriber

final class SpeakerCountViewTests: XCTestCase {

    // MARK: - speakerCountLabel (pure function)

    func testSpeakerCountLabelZero() {
        XCTAssertEqual(speakerCountLabel(0), "Auto-detect")
    }

    func testSpeakerCountLabelNonZero() {
        XCTAssertEqual(speakerCountLabel(3), "3 speakers")
    }

    // MARK: - View rendering

    private func makeRequest(title: String = "Standup") -> SpeakerCountRequest {
        SpeakerCountRequest(version: 1, timestamp: "2024-01-01T00:00:00", meetingTitle: title)
    }

    func testViewShowsMeetingTitle() throws {
        let sut = SpeakerCountView(request: makeRequest(title: "Planning"), onComplete: { _ in })
        let body = try sut.inspect()
        // Header uses string interpolation (LocalizedStringKey); extract all texts and check
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("Planning") == true }
        XCTAssertTrue(found, "Meeting title 'Planning' not found in any Text view")
    }

    func testConfirmButtonExists() throws {
        let sut = SpeakerCountView(request: makeRequest(), onComplete: { _ in })
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Confirm"))
    }

    func testAutoDetectButtonExists() throws {
        let sut = SpeakerCountView(request: makeRequest(), onComplete: { _ in })
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Auto-detect"))
    }

    // MARK: - Button taps

    func testConfirmButtonCallsOnComplete() throws {
        var result: Int?
        let sut = SpeakerCountView(request: makeRequest(), onComplete: { result = $0 })
        let body = try sut.inspect()
        try body.find(button: "Confirm").tap()
        XCTAssertEqual(result, 0) // default speakerCount is 0
    }

    func testAutoDetectButtonCallsOnCompleteWithZero() throws {
        var result: Int?
        let sut = SpeakerCountView(request: makeRequest(), onComplete: { result = $0 })
        let body = try sut.inspect()
        try body.find(button: "Auto-detect").tap()
        XCTAssertEqual(result, 0)
    }

    func testSpeakerCountLabelOne() {
        XCTAssertEqual(speakerCountLabel(1), "1 speakers")
    }

    func testInitialStepperShowsAutoDetect() throws {
        let sut = SpeakerCountView(request: makeRequest(), onComplete: { _ in })
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Auto-detect"))
    }
}
