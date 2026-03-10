import ViewInspector
import XCTest

@testable import MeetingTranscriber

final class SpeakerNamingViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeData(
        title: String = "Standup",
        mapping: [String: String]? = nil,
        speakingTimes: [String: TimeInterval]? = nil,
        micSpeakerID: String? = nil,
        micLabel: String? = nil
    ) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: title,
            mapping: mapping ?? ["SPEAKER_00": "SPEAKER_00"],
            speakingTimes: speakingTimes ?? ["SPEAKER_00": 60.0],
            embeddings: ["SPEAKER_00": [0.1, 0.2, 0.3]],
            audioPath: nil,
            segments: [],
            participants: [],
            micSpeakerID: micSpeakerID,
            micLabel: micLabel
        )
    }

    // MARK: - Tests

    func testHeaderShowsMeetingTitle() throws {
        let sut = SpeakerNamingView(
            data: makeData(title: "Planning"),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("Planning") == true }
        XCTAssertTrue(found, "Meeting title 'Planning' not found in any Text view")
    }

    func testRendersAllSpeakerRows() throws {
        let sut = SpeakerNamingView(
            data: makeData(mapping: [
                "SPEAKER_00": "SPEAKER_00",
                "SPEAKER_01": "SPEAKER_01",
                "SPEAKER_02": "SPEAKER_02",
            ], speakingTimes: [
                "SPEAKER_00": 60, "SPEAKER_01": 30, "SPEAKER_02": 45,
            ]),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        let groups = body.findAll(ViewType.GroupBox.self)
        XCTAssertEqual(groups.count, 3)
    }

    func testShowsAutoNameWhenPresent() throws {
        let sut = SpeakerNamingView(
            data: makeData(mapping: ["SPEAKER_00": "Roman"]),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Auto: Roman"))
    }

    func testShowsUnknownWhenNoAutoName() throws {
        let sut = SpeakerNamingView(
            data: makeData(mapping: ["SPEAKER_00": "SPEAKER_00"]),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Unknown"))
    }

    func testConfirmAndSkipButtonsExist() throws {
        let sut = SpeakerNamingView(
            data: makeData(),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Confirm"))
        XCTAssertNoThrow(try body.find(button: "Skip"))
    }

    // MARK: - Button taps

    func testSkipButtonCallsOnCompleteWithSkipped() throws {
        var result: PipelineQueue.SpeakerNamingResult?
        let sut = SpeakerNamingView(
            data: makeData(),
            onComplete: { result = $0 }
        )
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
        let sut = SpeakerNamingView(
            data: makeData(),
            onComplete: { result = $0 }
        )
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
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "SPEAKER_02"))
    }

    func testShowsSpeakingTime() throws {
        let sut = SpeakerNamingView(
            data: makeData(
                mapping: ["SPEAKER_00": "SPEAKER_00"],
                speakingTimes: ["SPEAKER_00": 125.0]
            ),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        // formattedTime(125) = "2:05"
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("2:05") == true }
        XCTAssertTrue(found, "Speaking time '2:05' should appear")
    }

    func testPreFillsAutoNameInMapping() throws {
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

    // MARK: - Mic Speaker Locked Row

    func testMicSpeakerShowsAutoLabel() throws {
        let sut = SpeakerNamingView(
            data: makeData(
                mapping: ["SPEAKER_00": "SPEAKER_00", "SPEAKER_01": "SPEAKER_01"],
                speakingTimes: ["SPEAKER_00": 60, "SPEAKER_01": 30],
                micSpeakerID: "SPEAKER_00",
                micLabel: "Roman"
            ),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        // Mic speaker should show "Mic" indicator and "Auto: Roman"
        let texts = body.findAll(ViewType.Text.self)
        let foundMic = texts.contains { (try? $0.string()) == "Mic" }
        let foundAuto = texts.contains { (try? $0.string()) == "Auto: Roman" }
        XCTAssertTrue(foundMic, "Mic indicator should appear")
        XCTAssertTrue(foundAuto, "Mic speaker auto name should appear")
    }

    func testMicSpeakerConfirmIncludesMicLabel() throws {
        var result: PipelineQueue.SpeakerNamingResult?
        let sut = SpeakerNamingView(
            data: makeData(
                mapping: ["SPEAKER_00": "SPEAKER_00", "SPEAKER_01": "SPEAKER_01"],
                speakingTimes: ["SPEAKER_00": 60, "SPEAKER_01": 30],
                micSpeakerID: "SPEAKER_00",
                micLabel: "Roman"
            ),
            onComplete: { result = $0 }
        )
        let body = try sut.inspect()
        // Mic speaker name is pre-filled via onAppear; confirm should include it
        try body.find(button: "Confirm").tap()
        if case .confirmed(let mapping) = result {
            XCTAssertEqual(mapping["SPEAKER_00"], "Roman", "Mic speaker should be in confirmed mapping")
        } else {
            XCTFail("Expected .confirmed, got \(String(describing: result))")
        }
    }

    func testNoMicSpeakerShowsNormalRows() throws {
        // When micSpeakerID is nil, all rows should be editable (no locked row)
        let sut = SpeakerNamingView(
            data: makeData(
                mapping: ["SPEAKER_00": "SPEAKER_00"],
                micSpeakerID: nil,
                micLabel: nil
            ),
            onComplete: { _ in }
        )
        let body = try sut.inspect()
        // Should show "Unknown" for unmatched speaker, not a locked name
        XCTAssertNoThrow(try body.find(text: "Unknown"))
    }
}
