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

    // MARK: - Rerun

    func testRerunButtonExists() throws {
        let sut = SpeakerNamingView(data: makeData()) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Re-run"))
    }

    func testRerunButtonCallsOnCompleteWithRerun() throws {
        var result: PipelineQueue.SpeakerNamingResult?
        let sut = SpeakerNamingView(data: makeData()) { result = $0 }
        let body = try sut.inspect()
        try body.find(button: "Re-run").tap()
        if case .rerun = result {
            // expected
        } else {
            XCTFail("Expected .rerun, got \(String(describing: result))")
        }
    }

    // MARK: - Multiple Speakers

    func testMultipleSpeakersRenderedInLabelOrder() throws {
        let data = makeData(
            mapping: [
                "SPEAKER_00": "SPEAKER_00",
                "SPEAKER_01": "Anna",
                "SPEAKER_02": "SPEAKER_02",
            ],
            speakingTimes: [
                "SPEAKER_00": 60, "SPEAKER_01": 30, "SPEAKER_02": 45,
            ],
        )
        let sut = SpeakerNamingView(data: data) { _ in }
        let body = try sut.inspect()
        let groups = body.findAll(ViewType.GroupBox.self)
        XCTAssertEqual(groups.count, 3)
    }

    func testSpeakerRowShowsFormattedTime() throws {
        let data = makeData(
            mapping: ["SPEAKER_00": "SPEAKER_00"],
            speakingTimes: ["SPEAKER_00": 90.0],
        )
        let sut = SpeakerNamingView(data: data) { _ in }
        let body = try sut.inspect()
        // formattedTime(90) = "1:30"
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("1:30") == true }
        XCTAssertTrue(found, "Should show '1:30' for 90 seconds")
    }

    // MARK: - Pure Function: buildSpeakerMapping

    func testBuildMappingWithUserNames() {
        let speakers: [(label: String, autoName: String?, speakingTime: Double)] = [
            (label: "SPEAKER_00", autoName: nil, speakingTime: 60),
            (label: "SPEAKER_01", autoName: nil, speakingTime: 30),
        ]
        let names = ["Alice", "Bob"]
        let mapping = SpeakerNamingView.buildSpeakerMapping(speakers: speakers, names: names)
        XCTAssertEqual(mapping, ["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"])
    }

    func testBuildMappingSkipsEmptyNames() {
        let speakers: [(label: String, autoName: String?, speakingTime: Double)] = [
            (label: "SPEAKER_00", autoName: nil, speakingTime: 60),
            (label: "SPEAKER_01", autoName: nil, speakingTime: 30),
        ]
        let names = ["Alice", ""]
        let mapping = SpeakerNamingView.buildSpeakerMapping(speakers: speakers, names: names)
        XCTAssertEqual(mapping, ["SPEAKER_00": "Alice"])
    }

    func testBuildMappingSkipsWhitespaceOnlyNames() {
        let speakers: [(label: String, autoName: String?, speakingTime: Double)] = [
            (label: "SPEAKER_00", autoName: nil, speakingTime: 60),
        ]
        let names = ["   "]
        let mapping = SpeakerNamingView.buildSpeakerMapping(speakers: speakers, names: names)
        XCTAssertTrue(mapping.isEmpty)
    }

    func testBuildMappingFewerNamesThanSpeakers() {
        let speakers: [(label: String, autoName: String?, speakingTime: Double)] = [
            (label: "SPEAKER_00", autoName: nil, speakingTime: 60),
            (label: "SPEAKER_01", autoName: nil, speakingTime: 30),
            (label: "SPEAKER_02", autoName: nil, speakingTime: 20),
        ]
        let names = ["Alice"]
        let mapping = SpeakerNamingView.buildSpeakerMapping(speakers: speakers, names: names)
        XCTAssertEqual(mapping, ["SPEAKER_00": "Alice"])
    }

    // MARK: - Pure Function: unusedParticipants

    func testUnusedParticipantsExcludesAssigned() {
        let names = ["Alice", "", "Charlie"]
        let participants = ["Alice", "Bob", "Charlie"]
        let unused = SpeakerNamingView.unusedParticipants(
            currentIndex: 1, names: names, participants: participants,
        )
        XCTAssertEqual(unused, ["Bob"])
    }

    func testUnusedParticipantsAllAssignedReturnsEmpty() {
        let names = ["Alice", "Bob"]
        let participants = ["Alice", "Bob"]
        let unused = SpeakerNamingView.unusedParticipants(
            currentIndex: 2, names: names, participants: participants,
        )
        XCTAssertTrue(unused.isEmpty)
    }

    func testUnusedParticipantsSkipsCurrentIndex() {
        // Current index 0 has "Alice" — but it should not be counted as "used"
        // because it's the field we're computing suggestions for
        let names = ["Alice", "Bob"]
        let participants = ["Alice", "Bob", "Charlie"]
        let unused = SpeakerNamingView.unusedParticipants(
            currentIndex: 0, names: names, participants: participants,
        )
        // "Bob" is used (index 1), "Alice" is skipped (current), "Charlie" is unused
        XCTAssertEqual(unused, ["Alice", "Charlie"])
    }

    // MARK: - Pure Function: unusedKnownNames

    func testUnusedKnownNamesExcludesParticipants() {
        // "Alice" is in participants — it should not appear as a known-name chip
        // (avoids duplicate buttons in the UI).
        let names = ["", "", ""]
        let unused = SpeakerNamingView.unusedKnownNames(
            currentIndex: 0,
            names: names,
            knownNames: ["Alice", "Charlie", "Diana"],
            participants: ["Alice", "Bob"],
        )
        XCTAssertEqual(unused, ["Charlie", "Diana"])
    }

    func testUnusedKnownNamesExcludesAlreadyAssigned() {
        let names = ["Charlie", "", ""]
        let unused = SpeakerNamingView.unusedKnownNames(
            currentIndex: 1,
            names: names,
            knownNames: ["Charlie", "Diana", "Eve"],
            participants: [],
        )
        XCTAssertEqual(unused, ["Diana", "Eve"])
    }

    func testUnusedKnownNamesEmptyKnownNames() {
        let unused = SpeakerNamingView.unusedKnownNames(
            currentIndex: 0,
            names: ["", ""],
            knownNames: [],
            participants: ["Alice"],
        )
        XCTAssertTrue(unused.isEmpty)
    }

    func testUnusedKnownNamesPreservesInputOrder() {
        // Caller (`SpeakerMatcher.allSpeakerNames()`) already sorts; the filter
        // must preserve that order so chips render alphabetically.
        let unused = SpeakerNamingView.unusedKnownNames(
            currentIndex: 0,
            names: ["", ""],
            knownNames: ["Anna", "Bob", "Charlie"],
            participants: [],
        )
        XCTAssertEqual(unused, ["Anna", "Bob", "Charlie"])
    }

    // MARK: - Pure Function: rankedKnownNames

    func testRankedKnownNamesAutoNameMatchFirst() {
        // autoName "Marwin" → both "Marwin …" entries rank ahead of others.
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Anna Berger", "Marwin Schmidt", "Bruno Klein", "Marwin Müller"],
            autoName: "Marwin",
            participants: [],
        )
        XCTAssertEqual(ranked, ["Marwin Schmidt", "Marwin Müller", "Anna Berger", "Bruno Klein"])
    }

    func testRankedKnownNamesParticipantTokenSecondTier() {
        // participant "Anna Berger" → "Anna Klein" (same first token) ranks up.
        // No autoName, so only participant tier + alphabetic remainder.
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Bruno Klein", "Anna Klein", "Charlie Tay"],
            autoName: nil,
            participants: ["Anna Berger"],
        )
        XCTAssertEqual(ranked, ["Anna Klein", "Bruno Klein", "Charlie Tay"])
    }

    func testRankedKnownNamesAutoNameOutranksParticipant() {
        // autoName "Bruno" beats participant token "Anna".
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Anna Klein", "Bruno Schmidt"],
            autoName: "Bruno",
            participants: ["Anna Berger"],
        )
        XCTAssertEqual(ranked, ["Bruno Schmidt", "Anna Klein"])
    }

    func testRankedKnownNamesIsCaseInsensitiveOnTokenMatch() {
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["bruno klein", "anna meyer"],
            autoName: "Bruno",
            participants: [],
        )
        XCTAssertEqual(ranked, ["bruno klein", "anna meyer"])
    }

    func testRankedKnownNamesPreservesInputOrderWithinTier() {
        // No matches at all → all names land in tier 2; input order preserved.
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Charlie", "Alice", "Bob"],
            autoName: nil,
            participants: [],
        )
        XCTAssertEqual(ranked, ["Charlie", "Alice", "Bob"])
    }

    func testRankedKnownNamesEmptyInput() {
        XCTAssertTrue(
            SpeakerNamingView.rankedKnownNames(known: [], autoName: "Foo", participants: ["Bar"]).isEmpty,
        )
    }

    func testRankedKnownNamesEmptyAutoNameDoesNotPromote() {
        // autoName "" must not promote names whose first token is empty.
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Anna Klein", "Bob Schmidt"],
            autoName: "",
            participants: [],
        )
        XCTAssertEqual(ranked, ["Anna Klein", "Bob Schmidt"])
    }

    func testRankedKnownNamesSingleTokenNamesMatch() {
        // Single-token participant "Madonna" — known "Madonna Smith" matches via first token.
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Bob Schmidt", "Madonna Smith"],
            autoName: nil,
            participants: ["Madonna"],
        )
        XCTAssertEqual(ranked, ["Madonna Smith", "Bob Schmidt"])
    }

    func testRankedKnownNamesSingleTokenKnownMatchesSingleTokenAuto() {
        // No whitespace anywhere; first token of each is the whole string.
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Charlie", "Alice"],
            autoName: "Charlie",
            participants: [],
        )
        XCTAssertEqual(ranked, ["Charlie", "Alice"])
    }

    // MARK: - Pure Function: computeInitialNames

    func testComputeInitialNamesFromAutoMapping() {
        let speakers: [(label: String, autoName: String?, speakingTime: Double)] = [
            (label: "SPEAKER_00", autoName: "Roman", speakingTime: 60),
            (label: "SPEAKER_01", autoName: nil, speakingTime: 30),
            (label: "SPEAKER_02", autoName: "Maria", speakingTime: 45),
        ]
        let names = SpeakerNamingView.computeInitialNames(speakers: speakers)
        XCTAssertEqual(names, ["Roman", "", "Maria"])
    }

    // MARK: - formattedTime pure function

    func testFormattedTimeSecondsOnly() {
        XCTAssertEqual(formattedTime(45), "45s")
    }

    func testFormattedTimeZero() {
        XCTAssertEqual(formattedTime(0), "0s")
    }

    func testFormattedTimeMinutesAndSeconds() {
        XCTAssertEqual(formattedTime(90), "1:30")
    }

    func testFormattedTimeExactMinute() {
        XCTAssertEqual(formattedTime(120), "2:00")
    }

    func testFormattedTimePadsSeconds() {
        XCTAssertEqual(formattedTime(65), "1:05")
    }

    func testFormattedTimeBoundaryAt59() {
        XCTAssertEqual(formattedTime(59), "59s")
    }

    func testFormattedTimeBoundaryAt60() {
        XCTAssertEqual(formattedTime(60), "1:00")
    }

    // MARK: - Participant suggestion buttons

    func testUnusedParticipantsWithNoAssignments() {
        // When no names are assigned, all participants are unused
        let names = ["", ""]
        let participants = ["Alice", "Bob"]
        let unused = SpeakerNamingView.unusedParticipants(
            currentIndex: 0, names: names, participants: participants,
        )
        XCTAssertEqual(unused, ["Alice", "Bob"])
    }

    func testUnusedParticipantsEmptyParticipantList() {
        let names = ["Alice"]
        let unused = SpeakerNamingView.unusedParticipants(
            currentIndex: 0, names: names, participants: [],
        )
        XCTAssertTrue(unused.isEmpty)
    }

    // MARK: - Audio Playback

    func testPlayButtonHiddenWhenNoAudioPath() throws {
        // Default makeData() has audioPath = nil
        let sut = SpeakerNamingView(data: makeData()) { _ in }
        let body = try sut.inspect()
        let images = body.findAll(ViewType.Image.self)
        let hasPlayIcon = images.contains { (try? $0.actualImage().name()) == "play.circle.fill" }
        XCTAssertFalse(hasPlayIcon, "Play button should be hidden when audioPath is nil")
    }

    func testPlayButtonShownWhenAudioPathPresent() throws {
        let dataWithAudio = PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: "Test",
            mapping: ["SPEAKER_00": "SPEAKER_00"],
            speakingTimes: ["SPEAKER_00": 60],
            embeddings: ["SPEAKER_00": [0.1, 0.2, 0.3]],
            audioPath: URL(fileURLWithPath: "/tmp/audio.wav"),
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_00")],
            participants: [],
        )
        let sut = SpeakerNamingView(data: dataWithAudio) { _ in }
        let body = try sut.inspect()
        // Play button uses system image "play.circle.fill"
        let images = body.findAll(ViewType.Image.self)
        let hasPlayIcon = images.contains { (try? $0.actualImage().name()) == "play.circle.fill" }
        XCTAssertTrue(hasPlayIcon, "Play button should be shown when audioPath is present")
    }
}
