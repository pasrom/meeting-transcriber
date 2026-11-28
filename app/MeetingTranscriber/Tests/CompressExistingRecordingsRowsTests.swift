@testable import MeetingTranscriber
import os
import ViewInspector
import XCTest

/// The "Compress Existing Recordings" rows in Settings → Output: the button
/// asks first, the confirmation starts the compactor's run, Cancel stops it,
/// and the button says why when it cannot be used. One test per control.
@MainActor
final class CompressExistingRecordingsRowsTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var fixture: RetentionQueueFixture!
    private var suiteName: String!
    // swiftlint:enable implicitly_unwrapped_optional
    private var starts = 0

    override func setUp() async throws {
        try await super.setUp()
        fixture = try RetentionQueueFixture(tmpDir: makeTempDirectory(prefix: "compress_existing_rows"))
        fixture.enabled = false
        suiteName = "CompressExistingRecordingsRowsTests-\(getpid())-\(UUID().uuidString)"
        starts = 0
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(suiteName)
        fixture = nil
        try await super.tearDown()
    }

    private func makeState(
        _ compaction: RecordingCompaction, count: Int = 2, compress: (() async -> Void)? = nil,
    ) -> CompressExistingRecordingsState {
        CompressExistingRecordingsState(
            compaction: compaction, countCompressible: { count },
            compress: compress ?? { [weak self] in self?.starts += 1 },
        )
    }

    /// The rows as Settings → Output shows them, inside the Recording
    /// Storage section, so the test also pins that they are placed there.
    private func makeView(_ state: CompressExistingRecordingsState) throws -> OutputSettingsView {
        try OutputSettingsView(settings: AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suiteName))), compressExisting: state)
    }

    private func button(_ id: String, in view: OutputSettingsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: id).button()
    }

    private func caption(_ id: String, in view: OutputSettingsView) throws -> String {
        try view.inspect().find(viewWithAccessibilityIdentifier: id).text().string()
    }

    // MARK: - The button and the confirmation

    func testCompressExistingButtonAsksBeforeItStartsARun() throws {
        let state = makeState(fixture.makeCompaction(), count: 3)

        try button(A11yID.compressExistingRecordingsButton, in: makeView(state)).tap()

        XCTAssertTrue(state.isConfirming)
        XCTAssertEqual(state.confirmationCount, 3)
        XCTAssertEqual(starts, 0, "started without a confirmation")
    }

    func testConfirmingStartsARun() async throws {
        let state = makeState(fixture.makeCompaction(), count: 3)
        state.requestConfirmation()

        let dialog = try makeView(state).inspect()
            .find(ViewType.HStack.self) { row in
                (try? row.find(viewWithAccessibilityIdentifier: A11yID.compressExistingRecordingsButton)) != nil
            }
            .confirmationDialog()
        XCTAssertEqual(try dialog.message().text().string(), CompressExistingRecordingsText.confirmationMessage(count: 3))
        try dialog.actions().button().tap()

        await waitFor(starts == 1, timeout: .seconds(5))
        XCTAssertEqual(starts, 1)
    }

    /// Through the controller's real entry: the confirmation's run converts
    /// an unmarked recording with the setting off.
    func testConfirmingRunsTheCompactorOverEveryEntry() async throws {
        let compaction = fixture.makeCompaction { false }
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        let state = makeState(compaction) { await queue.compactRecordings(.everyEntry) }

        await state.confirm().value

        XCTAssertTrue(try tracks.map(compressedTrack).allSatisfy(CompactionDisk.exists))
        XCTAssertNoThrow(try caption(A11yID.compressExistingRecordingsSummary, in: makeView(state)))
    }

    // MARK: - Cancel

    func testCancelButtonCancelsTheRun() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps) { false }
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        let state = makeState(compaction) { await queue.compactRecordings(.everyEntry) }
        let run = state.confirm()
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        let view = try makeView(state)
        XCTAssertTrue(try button(A11yID.compressExistingRecordingsButton, in: view).isDisabled(), "a second run could start")
        XCTAssertEqual(
            try caption(A11yID.compressExistingRecordingsProgress, in: view),
            "Compressing recordings: 0 of 3 files done.",
        )
        try button(A11yID.compressExistingRecordingsCancelButton, in: view).tap()
        gate.open()
        await run.value

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists), "a WAV went after the cancel")
        XCTAssertEqual(compaction.lastRequestedRun?.cancelled, true)
        XCTAssertThrowsError(try button(A11yID.compressExistingRecordingsCancelButton, in: makeView(state)))
    }

    // MARK: - Disabled, with the reason

    func testCompressExistingButtonIsDisabledWithoutFLAC() throws {
        let state = makeState(fixture.makeCompaction(codec: .unavailable(reason: "notNativeFLAC")))
        let view = try makeView(state)

        XCTAssertTrue(try button(A11yID.compressExistingRecordingsButton, in: view).isDisabled())
        XCTAssertEqual(try caption(A11yID.compressExistingRecordingsUnavailable, in: view), "Unavailable: this Mac cannot write FLAC.")
    }

    func testCompressExistingButtonIsDisabledWhileTheProbeHasNotConfirmedFLAC() throws {
        let view = try makeView(makeState(fixture.makeCompaction(codec: .unknown)))

        XCTAssertTrue(try button(A11yID.compressExistingRecordingsButton, in: view).isDisabled())
        XCTAssertNoThrow(try caption(A11yID.compressExistingRecordingsUnavailable, in: view))
    }

    func testCompressExistingButtonIsDisabledWithNothingToCompress() throws {
        let view = try makeView(makeState(fixture.makeCompaction(), count: 0))

        XCTAssertTrue(try button(A11yID.compressExistingRecordingsButton, in: view).isDisabled())
        XCTAssertEqual(
            try caption(A11yID.compressExistingRecordingsUnavailable, in: view),
            "No tracked recording in the output folder can be compressed now.",
        )
    }

    func testCompressExistingButtonIsUsableWithFLACAndARecording() throws {
        let view = try makeView(makeState(fixture.makeCompaction(), count: 1))

        XCTAssertFalse(try button(A11yID.compressExistingRecordingsButton, in: view).isDisabled())
        XCTAssertThrowsError(try caption(A11yID.compressExistingRecordingsUnavailable, in: view))
        XCTAssertThrowsError(try button(A11yID.compressExistingRecordingsCancelButton, in: view), "Cancel without a run")
    }

    /// An automatic run after a finished meeting is not the row's: no Cancel
    /// that would stop it, no progress line, and the button still usable,
    /// since a press queues behind that run.
    func testAnAutomaticRunShowsNoCancelAndLeavesTheButtonUsable() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        XCTAssertTrue(compaction.isRunning, "test premise: the automatic run is going")

        let view = try makeView(makeState(compaction, count: 1))
        let cancel = Result { try button(A11yID.compressExistingRecordingsCancelButton, in: view) }
        let progress = Result { try caption(A11yID.compressExistingRecordingsProgress, in: view) }
        let disabled = Result { try button(A11yID.compressExistingRecordingsButton, in: view).isDisabled() }
        gate.open()
        await waitForCompactionIdle(compaction)

        XCTAssertThrowsError(try cancel.get(), "a Cancel that would stop the automatic run")
        XCTAssertThrowsError(try progress.get())
        XCTAssertFalse(try disabled.get())
    }

    /// The user's run waits behind an automatic one: the row says so and
    /// offers Cancel; once cancelled the row is free at once, while the
    /// automatic run goes on, and the summary says the run was cancelled.
    func testCancellingAWaitingRunFreesTheRowAtOnce() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        let state = makeState(compaction, count: 1) { await queue.compactRecordings(.everyEntry) }
        let run = state.confirm()
        await waitFor(compaction.requestedRun == .waiting, timeout: .seconds(5))

        let waiting = try makeView(state)
        let waitingText = Result { try caption(A11yID.compressExistingRecordingsProgress, in: waiting) }
        let cancel = Result { try button(A11yID.compressExistingRecordingsCancelButton, in: waiting) }
        try cancel.get().tap()
        let after = try makeView(state)
        let cancelAfter = Result { try button(A11yID.compressExistingRecordingsCancelButton, in: after) }
        let disabledAfter = Result { try button(A11yID.compressExistingRecordingsButton, in: after).isDisabled() }
        let summaryAfter = Result { try caption(A11yID.compressExistingRecordingsSummary, in: after) }
        gate.open()
        await run.value
        await waitForCompactionIdle(compaction)

        XCTAssertEqual(try waitingText.get(), "Waiting for another conversion to finish\u{2026}")
        XCTAssertThrowsError(try cancelAfter.get(), "a Cancel for a run that is no longer queued")
        XCTAssertFalse(try disabledAfter.get(), "the row stayed busy after the cancel")
        XCTAssertTrue(try summaryAfter.get().contains("Cancelled"))
    }

    /// The registry is not observable, so the count is refreshed: a press on
    /// a button whose count went stale refreshes it instead of confirming
    /// "0 recordings", and the button then says why it is disabled.
    func testAPressOnAStaleCountRefreshesInsteadOfConfirming() throws {
        let count = CountBox(2)
        let state = CompressExistingRecordingsState(
            compaction: fixture.makeCompaction(), countCompressible: { count.value }, compress: {},
        )
        count.value = 0

        try button(A11yID.compressExistingRecordingsButton, in: makeView(state)).tap()

        XCTAssertFalse(state.isConfirming, "confirmed a count that is gone")
        XCTAssertTrue(try button(A11yID.compressExistingRecordingsButton, in: makeView(state)).isDisabled())
    }

    /// The rows' refresh task runs the count again, keyed on `refreshKey`.
    func testTheRefreshTaskRecountsUnderTheRefreshKey() async throws {
        let count = CountBox(0)
        let state = CompressExistingRecordingsState(
            compaction: fixture.makeCompaction(), countCompressible: { count.value }, compress: {},
        )
        let row = { [self] in
            try makeView(state).inspect().find(ViewType.HStack.self) { row in
                (try? row.find(viewWithAccessibilityIdentifier: A11yID.compressExistingRecordingsButton)) != nil
            }
        }
        count.value = 3

        try await row().callTask(id: state.refreshKey)

        XCTAssertEqual(state.compressibleCount, 3)
    }

    /// The key changes when a real run starts and when it ends, and when
    /// the tracks unfinished jobs hold change (a job finishing, which with
    /// the FLAC setting off starts no run): each change reruns the task.
    func testTheRefreshKeyFollowsARunAndTheHeldTracks() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let held = HeldBox()
        let state = CompressExistingRecordingsState(
            compaction: compaction, countCompressible: { 0 }, heldTracks: { held.value }, compress: {},
        )
        let idle = state.refreshKey

        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        let running = state.refreshKey
        gate.open()
        await waitForCompactionIdle(compaction)
        let after = state.refreshKey
        held.value = ["/a/job/track_mix.wav"]
        let afterAJobChanged = state.refreshKey

        XCTAssertNotEqual(running, idle, "a run starting does not rerun the refresh")
        XCTAssertNotEqual(after, running, "a run ending does not rerun the refresh")
        XCTAssertNotEqual(afterAJobChanged, after, "a job finishing does not rerun the refresh")
    }

    /// A second press between the confirmation and the run's start cannot
    /// queue a second run: the button is disabled from the confirmation on.
    func testTheButtonIsDisabledFromTheConfirmationOn() async throws {
        let entered = StepGate()
        let state = makeState(fixture.makeCompaction(), count: 3) { await entered.pass() }

        let run = state.confirm()
        let disabled = try button(A11yID.compressExistingRecordingsButton, in: makeView(state)).isDisabled()
        entered.open()
        await run.value

        XCTAssertTrue(disabled)
        XCTAssertFalse(try button(A11yID.compressExistingRecordingsButton, in: makeView(state)).isDisabled())
    }
}

/// A count the test changes after the state was built.
@MainActor
private final class CountBox {
    var value: Int

    init(_ value: Int) {
        self.value = value
    }
}

/// Held tracks the test changes after the state was built.
@MainActor
private final class HeldBox {
    var value: Set<String> = []
}
