@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class KnownVoicesViewTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "KnownVoicesViewTests")
        dbPath = tmpDir.appendingPathComponent("speakers.json")
    }

    func testViewRendersWithEmptyDB() throws {
        let view = KnownVoicesView(matcher: SpeakerMatcher(dbPath: dbPath))
        XCTAssertNoThrow(try view.inspect())
    }

    func testViewRendersWithSpeakers() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([
            StoredSpeaker(name: "Speaker A", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Speaker B", embeddings: [[0, 1, 0]]),
            StoredSpeaker(name: "Speaker C", embeddings: [[0, 0, 1]]),
        ])
        let view = KnownVoicesView(matcher: matcher)
        XCTAssertNoThrow(try view.inspect())
    }

    // MARK: - onMutate callback (cache invalidation gap, follow-up to #155)

    //
    // KnownVoicesView mutates the SpeakerMatcher's on-disk DB directly via
    // rename / delete / merge. Without notifying anyone, the PipelineQueue's
    // cached `knownSpeakerNames` (#155) goes stale — the next naming dialog
    // shows obsolete chips. The view now fires `onMutate` after every
    // successful mutation so the caller (SpeakersSettingsView wires it to
    // `pipelineQueue.refreshKnownSpeakerNames()`) can keep the cache fresh.

    func testRenameInvokesOnMutate() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "Old", embeddings: [[1, 0, 0]])])

        var calls = 0
        // Swift's trailing-closure disambiguation forces an explicit `onMutate:`
        // label here (KnownVoicesView has multiple closure params); SwiftLint's
        // trailing_closure rule disagrees but the compiler wins.
        // swiftlint:disable:next trailing_closure
        let view = KnownVoicesView(matcher: matcher, onMutate: { calls += 1 })

        view.performRename(from: "Old", to: "New")

        XCTAssertEqual(calls, 1)
    }

    func testDeleteInvokesOnMutate() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "Doomed", embeddings: [[1, 0, 0]])])

        var calls = 0
        // Swift's trailing-closure disambiguation forces an explicit `onMutate:`
        // label here (KnownVoicesView has multiple closure params); SwiftLint's
        // trailing_closure rule disagrees but the compiler wins.
        // swiftlint:disable:next trailing_closure
        let view = KnownVoicesView(matcher: matcher, onMutate: { calls += 1 })

        view.performDelete(name: "Doomed")

        XCTAssertEqual(calls, 1)
    }

    func testMergeInvokesOnMutate() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([
            StoredSpeaker(name: "From", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Into", embeddings: [[0, 1, 0]]),
        ])

        var calls = 0
        // Swift's trailing-closure disambiguation forces an explicit `onMutate:`
        // label here (KnownVoicesView has multiple closure params); SwiftLint's
        // trailing_closure rule disagrees but the compiler wins.
        // swiftlint:disable:next trailing_closure
        let view = KnownVoicesView(matcher: matcher, onMutate: { calls += 1 })

        view.performMerge(from: "From", into: "Into")

        XCTAssertEqual(calls, 1)
    }

    func testMissingOnMutateIsHandledGracefully() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "X", embeddings: [[1, 0, 0]])])
        let view = KnownVoicesView(matcher: matcher) // onMutate omitted
        // Mutations without a callback must not crash.
        view.performRename(from: "X", to: "Y")
    }

    // MARK: - Render

    func testRendersHeaderShowsTotalCount() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([
            StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Bob", embeddings: [[0, 1, 0]]),
        ])
        let view = KnownVoicesView(matcher: matcher)
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Known Voices"))
        XCTAssertNoThrow(try body.find(text: "2 total"))
    }

    func testRendersZeroTotalForEmptyDB() throws {
        let view = KnownVoicesView(matcher: SpeakerMatcher(dbPath: dbPath))
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "0 total"))
    }

    func testRendersActionButtonsDisabledWhenNoSelection() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]])])
        let view = KnownVoicesView(matcher: matcher)
        let body = try view.inspect()
        // Without a selection, the per-row action buttons are disabled. We
        // don't drive the Table selection from a test, so all three should
        // be disabled here.
        XCTAssertTrue(try body.find(button: "Rename").isDisabled())
        XCTAssertTrue(try body.find(button: "Merge into…").isDisabled())
        XCTAssertTrue(try body.find(button: "Delete").isDisabled())
    }

    func testRendersDoneButton() throws {
        let view = KnownVoicesView(matcher: SpeakerMatcher(dbPath: dbPath))
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(button: "Done"))
    }

    func testRendersAddFromRecordingButtonWhenFactoryProvided() throws {
        let view = KnownVoicesView(matcher: SpeakerMatcher(dbPath: dbPath)) {
            MockDiarization()
        }
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(button: "Add from Recording…"))
    }

    func testHidesAddFromRecordingButtonWhenFactoryNil() throws {
        let view = KnownVoicesView(matcher: SpeakerMatcher(dbPath: dbPath))
        let body = try view.inspect()
        XCTAssertThrowsError(try body.find(button: "Add from Recording…"))
    }

    func testPipelineBusyHintHiddenWhenFactoryNil() throws {
        let view = KnownVoicesView(
            matcher: SpeakerMatcher(dbPath: dbPath),
            pipelineBusy: true,
        )
        let body = try view.inspect()
        // Hint only shows when an enrollment factory is wired — without one
        // the user can't act on the hint anyway.
        XCTAssertThrowsError(try body.find(text: "Pipeline busy — diarization may be slower."))
    }

    // MARK: - KnownVoicesFormatting.lastUsedLabel (pure helper, extracted from view)

    func testLastUsedLabelReturnsDashForNil() {
        XCTAssertEqual(KnownVoicesFormatting.lastUsedLabel(nil), "—")
    }

    func testLastUsedLabelReturnsRelativeStringForDate() {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let label = KnownVoicesFormatting.lastUsedLabel(oneHourAgo)
        XCTAssertNotEqual(label, "—")
        XCTAssertFalse(label.isEmpty)
    }

    // MARK: - ActiveModal.id

    func testActiveModalRenameIdEmbedsName() {
        let modal = KnownVoicesView.ActiveModal.rename(name: "Alice", value: "Alice")
        XCTAssertEqual(modal.id, "rename:Alice")
    }

    func testActiveModalDeleteIdEmbedsName() {
        let modal = KnownVoicesView.ActiveModal.delete(name: "Bob")
        XCTAssertEqual(modal.id, "delete:Bob")
    }

    func testActiveModalMergeIdEmbedsFromName() {
        let modal = KnownVoicesView.ActiveModal.merge(from: "Charlie", destination: "Dave")
        XCTAssertEqual(modal.id, "merge:Charlie")
    }

    // MARK: - KnownVoicesFormatting.filterSpeakers (pure)

    private func speaker(_ name: String) -> StoredSpeaker {
        StoredSpeaker(name: name, embeddings: [[1, 0, 0]])
    }

    func testFilterSpeakersEmptyFilterReturnsAllUnchanged() {
        let speakers = [speaker("Alice"), speaker("Bob"), speaker("Charlie")]
        let result = KnownVoicesFormatting.filterSpeakers(speakers, by: "")
        XCTAssertEqual(result.map(\.name), ["Alice", "Bob", "Charlie"])
    }

    func testFilterSpeakersMatchesCaseInsensitiveSubstring() {
        let speakers = [speaker("Alice"), speaker("alex"), speaker("Bob")]
        let result = KnownVoicesFormatting.filterSpeakers(speakers, by: "AL")
        XCTAssertEqual(result.map(\.name), ["Alice", "alex"])
    }

    func testFilterSpeakersReturnsEmptyOnNoMatch() {
        let speakers = [speaker("Alice"), speaker("Bob")]
        let result = KnownVoicesFormatting.filterSpeakers(speakers, by: "xyz")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - KnownVoicesFormatting.mergeCandidateNames (pure)

    func testMergeCandidateNamesExcludesSource() {
        let speakers = [speaker("Alice"), speaker("Bob"), speaker("Charlie")]
        let result = KnownVoicesFormatting.mergeCandidateNames(in: speakers, excluding: "Bob")
        XCTAssertEqual(result, ["Alice", "Charlie"])
    }

    func testMergeCandidateNamesPreservesOrder() {
        let speakers = [speaker("Z"), speaker("A"), speaker("M")]
        let result = KnownVoicesFormatting.mergeCandidateNames(in: speakers, excluding: "A")
        XCTAssertEqual(result, ["Z", "M"])
    }

    func testMergeCandidateNamesUnknownSourceReturnsAll() {
        let speakers = [speaker("Alice"), speaker("Bob")]
        let result = KnownVoicesFormatting.mergeCandidateNames(in: speakers, excluding: "NotInList")
        XCTAssertEqual(result, ["Alice", "Bob"])
    }

    // MARK: - KnownVoicesFormatting.trimmedRenameValue (pure)

    func testTrimmedRenameValueReturnsTrimmedString() {
        XCTAssertEqual(KnownVoicesFormatting.trimmedRenameValue("  New Name  "), "New Name")
    }

    func testTrimmedRenameValueReturnsNilForEmpty() {
        XCTAssertNil(KnownVoicesFormatting.trimmedRenameValue(""))
    }

    func testTrimmedRenameValueReturnsNilForWhitespaceOnly() {
        XCTAssertNil(KnownVoicesFormatting.trimmedRenameValue("   \t\n  "))
    }
}
