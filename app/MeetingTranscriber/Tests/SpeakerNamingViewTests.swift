@testable import MeetingTranscriber
import ViewInspector
import XCTest

final class SpeakerNamingViewTests: XCTestCase {
    // MARK: - Helpers

    private func makeData(
        title: String = "Standup",
        mapping: [String: String] = ["SPEAKER_00": "SPEAKER_00"],
        speakingTimes: [String: TimeInterval] = ["SPEAKER_00": 60.0],
    ) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: title,
            mapping: mapping,
            speakingTimes: speakingTimes,
            embeddings: ["SPEAKER_00": [0.1, 0.2, 0.3]],
            audioPath: nil,
            segments: [],
            participants: [],
        )
    }

    // MARK: - Tests

    func testHeaderShowsMeetingTitle() throws {
        let sut = SpeakerNamingView(data: makeData(title: "Planning")) { _ in }
        let body = try sut.inspect()
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("Planning") == true }
        XCTAssertTrue(found, "Meeting title 'Planning' not found in any Text view")
    }

    func testRendersAllSpeakerRows() throws {
        let sut = SpeakerNamingView(data: makeData(mapping: [
            "SPEAKER_00": "SPEAKER_00",
            "SPEAKER_01": "SPEAKER_01",
            "SPEAKER_02": "SPEAKER_02",
        ], speakingTimes: [
            "SPEAKER_00": 60, "SPEAKER_01": 30, "SPEAKER_02": 45,
        ])) { _ in }
        let body = try sut.inspect()
        let groups = body.findAll(ViewType.GroupBox.self)
        XCTAssertEqual(groups.count, 3)
    }

    func testShowsAutoNameWhenPresent() throws {
        let sut = SpeakerNamingView(data: makeData(mapping: ["SPEAKER_00": "Roman"])) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Auto: Roman"))
    }

    func testShowsUnknownWhenNoAutoName() throws {
        let sut = SpeakerNamingView(data: makeData(mapping: ["SPEAKER_00": "SPEAKER_00"])) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Unknown"))
    }

    func testConfirmAndSkipButtonsExist() throws {
        let sut = SpeakerNamingView(data: makeData()) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Confirm"))
        XCTAssertNoThrow(try body.find(button: "Skip"))
    }

    // MARK: - Button taps

    func testSkipButtonCallsOnCompleteWithSkipped() throws {
        var result: PipelineQueue.SpeakerNamingResult?
        let sut = SpeakerNamingView(data: makeData()) { result = $0 }
        let body = try sut.inspect()
        try body.find(button: "Skip").tap()
        if case .skipped = result {
            // expected
        } else {
            XCTFail("Expected .skipped, got \(String(describing: result))")
        }
    }

    func testConfirmButtonCallsOnComplete() throws {
        var result: PipelineQueue.SpeakerNamingResult?
        let sut = SpeakerNamingView(data: makeData()) { result = $0 }
        let body = try sut.inspect()
        try body.find(button: "Confirm").tap()
        if case .confirmed = result {
            // expected
        } else {
            XCTFail("Expected .confirmed, got \(String(describing: result))")
        }
    }

    // MARK: - Speaker details

    func testShowsSpeakerLabel() throws {
        let sut = SpeakerNamingView(
            data: makeData(mapping: ["SPEAKER_02": "SPEAKER_02"], speakingTimes: ["SPEAKER_02": 120.0]),
        ) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "SPEAKER_02"))
    }

    func testShowsSpeakingTime() throws {
        let sut = SpeakerNamingView(data: makeData(
            mapping: ["SPEAKER_00": "SPEAKER_00"],
            speakingTimes: ["SPEAKER_00": 125.0],
        )) { _ in }
        let body = try sut.inspect()
        // formattedTime(125) = "2:05"
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("2:05") == true }
        XCTAssertTrue(found, "Speaking time '2:05' should appear")
    }

    func testPreFillsAutoNameInMapping() {
        // When mapping has a matched name (different from label), it's an auto name
        let data = makeData(mapping: ["SPEAKER_00": "Maria"])
        let speakers = data.mapping.keys.sorted().map { label in
            let autoName = data.mapping[label]
            let isAutoNamed = autoName != nil && autoName != label
            return (label: label, autoName: isAutoNamed ? autoName : nil)
        }
        let names = speakers.map { $0.autoName ?? "" }
        XCTAssertEqual(names.first, "Maria")
    }
}
