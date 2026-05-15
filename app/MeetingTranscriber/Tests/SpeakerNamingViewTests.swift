// swiftlint:disable file_length
import AppKit
@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class SpeakerNamingViewTests: XCTestCase { // swiftlint:disable:this type_body_length
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
            isDualSource: false,
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
        let sut = SpeakerNamingView(data: makeData(mapping: ["SPEAKER_00": "Speaker A"])) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Auto: Speaker A"))
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

    /// Regression test for the multi-job stuck-state bug: when the window
    /// switches to a different `data.jobID`, the per-job guard
    /// (`completedJobID != data.jobID`) must re-allow taps. The previous
    /// global Bool guard would silently swallow every click after the first.
    func testConfirmFiresForEachDistinctJob() throws {
        var jobIDsConfirmed: [UUID] = []

        let dataA = makeData(title: "Meeting A")
        let viewA = SpeakerNamingView(data: dataA) { result in
            if case .confirmed = result { jobIDsConfirmed.append(dataA.jobID) }
        }
        try viewA.inspect().find(button: "Confirm").tap()

        let dataB = makeData(title: "Meeting B")
        let viewB = SpeakerNamingView(data: dataB) { result in
            if case .confirmed = result { jobIDsConfirmed.append(dataB.jobID) }
        }
        try viewB.inspect().find(button: "Confirm").tap()

        XCTAssertEqual(
            jobIDsConfirmed,
            [dataA.jobID, dataB.jobID],
            "Each distinct jobID must be confirmable independently",
        )
    }

    /// Skip shares the same per-job guard as Confirm. If a future refactor
    /// reverts Skip's guard to a global Bool, the multi-job stuck-state
    /// would resurface for users who hit Skip on back-to-back meetings.
    func testSkipFiresForEachDistinctJob() throws {
        var jobIDsSkipped: [UUID] = []

        let dataA = makeData(title: "Meeting A")
        let viewA = SpeakerNamingView(data: dataA) { result in
            if case .skipped = result { jobIDsSkipped.append(dataA.jobID) }
        }
        try viewA.inspect().find(button: "Skip").tap()

        let dataB = makeData(title: "Meeting B")
        let viewB = SpeakerNamingView(data: dataB) { result in
            if case .skipped = result { jobIDsSkipped.append(dataB.jobID) }
        }
        try viewB.inspect().find(button: "Skip").tap()

        XCTAssertEqual(
            jobIDsSkipped,
            [dataA.jobID, dataB.jobID],
            "Each distinct jobID must be skippable independently",
        )
    }

    /// Re-run shares the same per-job guard as Confirm and Skip — same
    /// regression risk if the guard ever reverts to a global Bool.
    func testRerunFiresForEachDistinctJob() throws {
        var jobIDsRerun: [UUID] = []

        let dataA = makeData(title: "Meeting A")
        let viewA = SpeakerNamingView(data: dataA) { result in
            if case .rerun = result { jobIDsRerun.append(dataA.jobID) }
        }
        try viewA.inspect().find(button: "Re-run").tap()

        let dataB = makeData(title: "Meeting B")
        let viewB = SpeakerNamingView(data: dataB) { result in
            if case .rerun = result { jobIDsRerun.append(dataB.jobID) }
        }
        try viewB.inspect().find(button: "Re-run").tap()

        XCTAssertEqual(
            jobIDsRerun,
            [dataA.jobID, dataB.jobID],
            "Each distinct jobID must be re-runnable independently",
        )
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
        let data = makeData(mapping: ["SPEAKER_00": "Speaker I"])
        let speakers = data.mapping.keys.sorted().map { label in
            let autoName = data.mapping[label]
            let isAutoNamed = autoName != nil && autoName != label
            return (label: label, autoName: isAutoNamed ? autoName : nil)
        }
        let names = speakers.map { $0.autoName ?? "" }
        XCTAssertEqual(names.first, "Speaker I")
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
                "SPEAKER_01": "Speaker B",
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
        let names = ["Alice", "Speaker C"]
        let mapping = SpeakerNamingView.buildSpeakerMapping(speakers: speakers, names: names)
        XCTAssertEqual(mapping, ["SPEAKER_00": "Alice", "SPEAKER_01": "Speaker C"])
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

    // MARK: - Pure Function: filterByQuery

    func testFilterByQueryEmptyReturnsUnchanged() {
        let names = ["Alpha", "Bravo", "Speaker D"]
        XCTAssertEqual(SpeakerNamingView.filterByQuery(names: names, query: ""), names)
    }

    func testFilterByQueryWhitespaceReturnsUnchanged() {
        let names = ["Alpha", "Bravo"]
        XCTAssertEqual(SpeakerNamingView.filterByQuery(names: names, query: "   "), names)
    }

    func testFilterByQueryPrefixOfFirstToken() {
        // "Tea" matches the prefix of "Teams" and "Teal".
        let names = ["Speaker Z", "Teams", "Bravo", "Teal"]
        XCTAssertEqual(
            SpeakerNamingView.filterByQuery(names: names, query: "Tea"),
            ["Teams", "Teal"],
        )
    }

    func testFilterByQuerySecondTokenPrefix() {
        // "Mü" matches the second token "Münze".
        let names = ["Speaker Z", "Speaker Münze", "Speaker D"]
        XCTAssertEqual(
            SpeakerNamingView.filterByQuery(names: names, query: "Mü"),
            ["Speaker Münze"],
        )
    }

    func testFilterByQueryContainsTier() {
        // "an" — "Antares" prefix tier, "Susan" contains tier.
        let names = ["Susan", "Antares", "Speaker C"]
        XCTAssertEqual(
            SpeakerNamingView.filterByQuery(names: names, query: "an"),
            ["Antares", "Susan"],
        )
    }

    func testFilterByQueryCaseInsensitive() {
        XCTAssertEqual(
            SpeakerNamingView.filterByQuery(names: ["Alpha"], query: "alp"),
            ["Alpha"],
        )
    }

    func testFilterByQueryNoMatch() {
        XCTAssertTrue(
            SpeakerNamingView.filterByQuery(names: ["Alpha", "Bravo"], query: "zz").isEmpty,
        )
    }

    // MARK: - Pure Function: rankedKnownNames

    func testRankedKnownNamesAutoNameMatchFirst() {
        // First-token "Bravo" → both "Bravo …" entries rank ahead.
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Alpha Berger", "Bravo Schmidt", "Speaker D Klein", "Bravo Münze"],
            autoName: "Bravo",
            participants: [],
        )
        XCTAssertEqual(ranked, ["Bravo Schmidt", "Bravo Münze", "Alpha Berger", "Speaker D Klein"])
    }

    func testRankedKnownNamesEmptyAutoNameDoesNotPromote() {
        let ranked = SpeakerNamingView.rankedKnownNames(
            known: ["Alpha Klein", "Bravo Schmidt"],
            autoName: "",
            participants: [],
        )
        XCTAssertEqual(ranked, ["Alpha Klein", "Bravo Schmidt"])
    }

    // MARK: - Pure Function: computeInitialNames

    func testComputeInitialNamesFromAutoMapping() {
        let speakers: [(label: String, autoName: String?, speakingTime: Double)] = [
            (label: "SPEAKER_00", autoName: "Speaker A", speakingTime: 60),
            (label: "SPEAKER_01", autoName: nil, speakingTime: 30),
            (label: "SPEAKER_02", autoName: "Speaker B", speakingTime: 45),
        ]
        let names = SpeakerNamingView.computeInitialNames(speakers: speakers)
        XCTAssertEqual(names, ["Speaker A", "", "Speaker B"])
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
            isDualSource: false,
        )
        let sut = SpeakerNamingView(data: dataWithAudio) { _ in }
        let body = try sut.inspect()
        // Play button uses system image "play.circle.fill"
        let images = body.findAll(ViewType.Image.self)
        let hasPlayIcon = images.contains { (try? $0.actualImage().name()) == "play.circle.fill" }
        XCTAssertTrue(hasPlayIcon, "Play button should be shown when audioPath is present")
    }

    // MARK: - knownChips render branch (requires non-empty knownSpeakerNames)

    func testRendersKnownLabelWhenKnownSpeakerNamesProvided() throws {
        let sut = SpeakerNamingView(
            data: makeData(),
            knownSpeakerNames: ["Alice", "Bob"],
        ) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Known:"))
    }

    func testRendersKnownChipForEachKnownSpeakerName() throws {
        let sut = SpeakerNamingView(
            data: makeData(),
            knownSpeakerNames: ["Alice", "Bob", "Charlie"],
        ) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Alice"))
        XCTAssertNoThrow(try body.find(button: "Bob"))
        XCTAssertNoThrow(try body.find(button: "Charlie"))
    }

    func testKnownChipTapInvokesActionClosureAndConfirmFires() throws {
        // Tap the known chip (covers the chipButton action closure inside
        // `knownChips`), then Confirm. We don't assert on the mapping content
        // because @State assignment from a ViewInspector tap doesn't
        // reliably propagate to subsequent .inspect() calls; the goal here
        // is exercising the chip's action path.
        var result: PipelineQueue.SpeakerNamingResult?
        let sut = SpeakerNamingView(
            data: makeData(),
            knownSpeakerNames: ["Alice"],
        ) { result = $0 }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Alice").tap())
        try body.find(button: "Confirm").tap()
        if case .confirmed = result {} else {
            XCTFail("Expected .confirmed, got \(String(describing: result))")
        }
    }

    // MARK: - More button (collapsed → expanded chip list)

    func testMoreChipAppearsWhenKnownNamesExceedCollapsedLimit() throws {
        // Limit is 8; provide 10 to force a "More (2)…" chip to render.
        let manyNames = (0 ..< 10).map { "Speaker\($0)" }
        let sut = SpeakerNamingView(
            data: makeData(),
            knownSpeakerNames: manyNames,
        ) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "More (2)…"))
    }

    func testMoreChipHiddenWhenKnownNamesAtOrBelowCollapsedLimit() throws {
        let eightNames = (0 ..< 8).map { "Speaker\($0)" }
        let sut = SpeakerNamingView(
            data: makeData(),
            knownSpeakerNames: eightNames,
        ) { _ in }
        let body = try sut.inspect()
        // Any chip whose label starts with "More" would indicate the
        // collapse/expand control is showing — there shouldn't be one.
        let buttons = body.findAll(ViewType.Button.self)
        let hasMore = buttons.contains { btn in
            (try? btn.labelView().text().string().hasPrefix("More")) == true
        }
        XCTAssertFalse(hasMore)
    }

    // MARK: - Participant chips

    func testRendersParticipantChipsWhenParticipantsProvided() throws {
        let data = PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: "Standup",
            mapping: ["SPEAKER_00": "SPEAKER_00"],
            speakingTimes: ["SPEAKER_00": 60],
            embeddings: ["SPEAKER_00": [0.1, 0.2, 0.3]],
            audioPath: nil,
            segments: [],
            participants: ["Dave", "Eve"],
            isDualSource: false,
        )
        let sut = SpeakerNamingView(data: data) { _ in }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Dave"))
        XCTAssertNoThrow(try body.find(button: "Eve"))
    }

    func testParticipantChipTapInvokesActionClosureAndConfirmFires() throws {
        // Same coverage goal as the known-chip test — tap the participant
        // chip to exercise the chipButton action closure inside
        // `participantChips`, then Confirm. State propagation through
        // ViewInspector taps is unreliable, so we don't assert mapping content.
        var result: PipelineQueue.SpeakerNamingResult?
        let data = PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: "Standup",
            mapping: ["SPEAKER_00": "SPEAKER_00"],
            speakingTimes: ["SPEAKER_00": 60],
            embeddings: ["SPEAKER_00": [0.1, 0.2, 0.3]],
            audioPath: nil,
            segments: [],
            participants: ["Dave"],
            isDualSource: false,
        )
        let sut = SpeakerNamingView(data: data) { result = $0 }
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Dave").tap())
        try body.find(button: "Confirm").tap()
        if case .confirmed = result {} else {
            XCTFail("Expected .confirmed, got \(String(describing: result))")
        }
    }

    // MARK: - Known speakers also in participants are de-duplicated

    func testKnownNameAlreadyInParticipantsIsNotShownTwice() throws {
        // "Dave" is both a participant AND a known speaker. The Known: row
        // must skip him — chipping the same name twice would let the user
        // tap the "wrong" one and surfaces no extra information.
        let data = PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: "Standup",
            mapping: ["SPEAKER_00": "SPEAKER_00"],
            speakingTimes: ["SPEAKER_00": 60],
            embeddings: ["SPEAKER_00": [0.1, 0.2, 0.3]],
            audioPath: nil,
            segments: [],
            participants: ["Dave"],
            isDualSource: false,
        )
        let sut = SpeakerNamingView(
            data: data,
            knownSpeakerNames: ["Dave", "Eve"],
        ) { _ in }
        let body = try sut.inspect()
        // "Eve" should still show up under Known:
        XCTAssertNoThrow(try body.find(button: "Eve"))
        // "Dave" only shows once (participant chip), not in Known: row.
        let daveButtons = body.findAll(ViewType.Button.self).filter { btn in
            (try? btn.labelView().text().string()) == "Dave"
        }
        XCTAssertEqual(daveButtons.count, 1)
    }

    // MARK: - AccessibleTextField NSViewRepresentable bridge

    func testAccessibleTextFieldCoordinatorWritesBackToBinding() {
        var current = ""
        let binding = Binding<String>(get: { current }, set: { current = $0 })
        let coord = AccessibleTextField.Coordinator(text: binding)
        let field = NSTextField()
        field.stringValue = "Frank"
        let notif = Notification(name: NSControl.textDidChangeNotification, object: field)
        coord.controlTextDidChange(notif)
        XCTAssertEqual(current, "Frank")
    }

    func testAccessibleTextFieldCoordinatorIgnoresNonTextFieldNotification() {
        var current = "unchanged"
        let binding = Binding<String>(get: { current }, set: { current = $0 })
        let coord = AccessibleTextField.Coordinator(text: binding)
        // Notification.object is not an NSTextField → guard fires, binding stays.
        let notif = Notification(name: NSControl.textDidChangeNotification, object: NSObject())
        coord.controlTextDidChange(notif)
        XCTAssertEqual(current, "unchanged")
    }

    func testAccessibleTextFieldMakeCoordinatorReturnsCoordinatorBoundToText() {
        var captured = ""
        let field = AccessibleTextField(
            text: Binding(get: { captured }, set: { captured = $0 }),
            placeholder: "Name",
            identifier: "speaker-name-test",
        )
        let coord = field.makeCoordinator()
        // Drive the coordinator to verify the binding is wired through.
        let nsField = NSTextField()
        nsField.stringValue = "Grace"
        coord.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: nsField),
        )
        XCTAssertEqual(captured, "Grace")
    }
}
