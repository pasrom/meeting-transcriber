@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The Settings row for WhisperKit models earlier builds left in `Documents`:
/// the scope the settings give it, the state behind it and the wiring of its
/// controls. What gets listed and trashed is pinned in
/// `LegacyWhisperModelInventoryTests`; the confirmation dialog's presentation
/// itself is manual QA. Everything runs on temp folders with a trash that moves
/// into a temp folder.
@MainActor
final class TranscriptionSettingsLegacyModelsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    private let small = "openai_whisper-small"
    private let base = "openai_whisper-base"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsLegacyModelsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    /// Moves each item into a temp folder, or fails for the names in `failing`.
    /// With a `gate`, each move first waits for it, so a test can look at the
    /// state while a removal is running.
    private final class FakeTrash: @unchecked Sendable {
        private let lock = NSLock()
        private let folder: URL
        private let failing: Set<String>
        private let gate: DispatchSemaphore?
        private var moved: [String] = []

        init(folder: URL, failing: Set<String> = [], gate: DispatchSemaphore? = nil) {
            self.folder = folder
            self.failing = failing
            self.gate = gate
        }

        var trashed: [String] {
            lock.withLock { moved }
        }

        func callAsFunction(_ url: URL) throws {
            gate?.wait()
            if failing.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
            try lock.withLock {
                try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(moved.count)-\(url.lastPathComponent)"))
                moved.append(url.lastPathComponent)
            }
        }
    }

    /// A value the scope closure reads and the test changes.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private struct Fixture {
        let legacyBase: URL
        let currentBase: URL
        let trash: FakeTrash

        var repoRoot: URL {
            WhisperKitModelMigration.legacyRepoRoot(for: WhisperKitLocalSnapshot.repoID, base: legacyBase)
        }

        var currentRepoRoot: URL {
            currentBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        }

        func scope(selected: String? = nil) -> LegacyWhisperModelInventory.Scope {
            .init(
                legacyBase: legacyBase,
                knownVariants: ["openai_whisper-small", "openai_whisper-base"],
                currentBase: currentBase,
                currentRepoRoot: currentRepoRoot,
                selectedVariant: selected,
            )
        }
    }

    /// The given variants at the old location, each with one 7-byte file.
    private func makeFixture(
        variants: [String],
        failing: Set<String> = [],
        gate: DispatchSemaphore? = nil,
    ) throws -> Fixture {
        let temp = try makeTempDirectory(prefix: "legacy-wk-state")
        let trashFolder = temp.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        let fixture = Fixture(
            legacyBase: temp.appendingPathComponent("Documents/huggingface", isDirectory: true),
            currentBase: temp.appendingPathComponent("AppSupport/huggingface", isDirectory: true),
            trash: FakeTrash(folder: trashFolder, failing: failing, gate: gate),
        )
        for variant in variants {
            let folder = fixture.repoRoot.appendingPathComponent(variant, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 7).write(to: folder.appendingPathComponent("config.json"))
        }
        return fixture
    }

    /// Every required file of a model, so the migration would take the folder.
    private func makeComplete(_ variant: String, in fixture: Fixture) throws {
        for relative in WhisperKitLocalSnapshot.requiredPaths() {
            let file = fixture.repoRoot.appendingPathComponent(variant).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 1).write(to: file)
        }
    }

    private func makeState(_ fixture: Fixture) -> LegacyWhisperModelsState {
        let scope = fixture.scope()
        return LegacyWhisperModelsState(scope: { scope }, trash: fixture.trash.callAsFunction)
    }

    private func makeView(_ state: LegacyWhisperModelsState?, settings: AppSettings? = nil) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings ?? AppSettings(defaults: defaults),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            legacyModels: state,
        )
    }

    private func trashButton(in view: TranscriptionSettingsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.legacyWhisperModelsTrashButton).button()
    }

    private func toggle(_ index: Int, in view: TranscriptionSettingsView) throws -> InspectableView<ViewType.Toggle> {
        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.legacyWhisperModelToggle(index)).toggle()
    }

    // MARK: - Scope from the settings

    func testTheScopeOffersThePickerVariantsAndProtectsTheSelectedOne() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitModel = small
        let legacyBase = URL(fileURLWithPath: "/tmp/old/huggingface", isDirectory: true)
        let currentBase = URL(fileURLWithPath: "/tmp/new/huggingface", isDirectory: true)

        let scope = try XCTUnwrap(LegacyWhisperModelsState.scope(for: settings, legacyBase: legacyBase, currentBase: currentBase))

        XCTAssertEqual(scope.knownVariants, Set(TranscriptionSettingsView.whisperKitModels.map(\.variant)))
        XCTAssertEqual(scope.selectedVariant, small)
        XCTAssertEqual(scope.pickedFolders, [])
        XCTAssertEqual(scope.repoRoot, WhisperKitModelMigration.legacyRepoRoot(for: WhisperKitLocalSnapshot.repoID, base: legacyBase))
        XCTAssertEqual(scope.currentBase, currentBase)
        XCTAssertEqual(scope.currentRepoRoot, WhisperKitLocalSnapshot.repoRoot(for: WhisperKitLocalSnapshot.repoID))
    }

    /// A custom variant of the stock repository was downloaded into the same
    /// folder; one of another repository was not, so it adds nothing.
    func testACustomVariantCountsOnlyInTheStockRepository() throws {
        let settings = AppSettings(defaults: defaults)
        let base = URL(fileURLWithPath: "/tmp/old/huggingface", isDirectory: true)
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = " \(WhisperKitLocalSnapshot.repoID) "
        settings.whisperKitCustomVariant = "openai_whisper-medium"

        let stock = try XCTUnwrap(LegacyWhisperModelsState.scope(for: settings, legacyBase: base))
        XCTAssertTrue(stock.knownVariants.contains("openai_whisper-medium"))
        XCTAssertEqual(stock.selectedVariant, "openai_whisper-medium")

        settings.whisperKitCustomRepo = "someone/finetune"
        let other = try XCTUnwrap(LegacyWhisperModelsState.scope(for: settings, legacyBase: base))
        XCTAssertFalse(other.knownVariants.contains("openai_whisper-medium"))
        XCTAssertNil(other.selectedVariant)
    }

    func testATypedModelFolderIsProtected() throws {
        let settings = AppSettings(defaults: defaults)
        let folder = URL(fileURLWithPath: "/tmp/old/huggingface/models/argmaxinc/whisperkit-coreml/\(small)", isDirectory: true)
        settings.setWhisperKitCustomModelFolderPath(folder.path)

        let scope = try XCTUnwrap(LegacyWhisperModelsState.scope(for: settings, legacyBase: URL(fileURLWithPath: "/tmp/old")))

        XCTAssertEqual(scope.pickedFolders.map(\.path), [folder.path])
    }

    /// A load reads the picked folder through its bookmark, which follows the
    /// folder when it moves; the shown path may be stale. Both protect.
    func testAPickedFolderIsProtectedWhereItsBookmarkLeads() async throws {
        let fixture = try makeFixture(variants: [small, base])
        let picked = fixture.repoRoot.deletingLastPathComponent().appendingPathComponent("picked", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults)
        settings.setWhisperKitCustomModelFolder(picked)
        try XCTSkipIf(settings.whisperKitCustomModelFolderBookmark == nil, "no bookmark could be made here")
        // The folder the bookmark names is now the small variant; the stored path is stale.
        try FileManager.default.removeItem(at: fixture.repoRoot.appendingPathComponent(small))
        try FileManager.default.moveItem(at: picked, to: fixture.repoRoot.appendingPathComponent(small))

        let state = LegacyWhisperModelsState(
            settings: settings,
            legacyBase: fixture.legacyBase,
            currentBase: fixture.currentBase,
            currentRepoRoot: fixture.currentRepoRoot,
            trash: fixture.trash.callAsFunction,
        )
        await state.refresh()

        XCTAssertEqual(state.models.map(\.variant), [base])
    }

    /// Nothing is read in `Documents` for a user who never ran WhisperKit since
    /// models moved: that read could be the first, and macOS would ask for it.
    func testNoScopeForAnInstallThatHasNotUsedWhisperKitSinceTheMove() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .parakeet
        let temp = try makeTempDirectory(prefix: "legacy-wk-gate")
        let legacyBase = temp.appendingPathComponent("Documents/huggingface")
        let currentBase = temp.appendingPathComponent("AppSupport/huggingface")

        XCTAssertNil(LegacyWhisperModelsState.scope(for: settings, legacyBase: legacyBase, currentBase: currentBase))

        try FileManager.default.createDirectory(at: currentBase, withIntermediateDirectories: true)
        XCTAssertNotNil(LegacyWhisperModelsState.scope(for: settings, legacyBase: legacyBase, currentBase: currentBase))
    }

    /// A repository name in another case is the same folder on the volume, so
    /// its variant is the stock one and the selected one.
    func testTheStockRepositoryIsRecognisedIgnoringCase() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "ArgmaxInc/WhisperKit-CoreML"
        settings.whisperKitCustomVariant = "openai_whisper-medium"

        let scope = try XCTUnwrap(LegacyWhisperModelsState.scope(for: settings, legacyBase: URL(fileURLWithPath: "/tmp/old")))

        XCTAssertTrue(scope.knownVariants.contains("openai_whisper-medium"))
        XCTAssertEqual(scope.selectedVariant, "openai_whisper-medium")
    }

    /// The pane rescans on any input the scope reads, the bookmark included.
    func testTheScopeInputsFollowEverySettingTheScopeReads() throws {
        let settings = AppSettings(defaults: defaults)
        let before = LegacyWhisperModelsState.ScopeInputs(settings)
        let folder = try makeTempDirectory(prefix: "legacy-wk-inputs")

        settings.setWhisperKitCustomModelFolder(folder)
        XCTAssertNotEqual(LegacyWhisperModelsState.ScopeInputs(settings), before)
        let picked = LegacyWhisperModelsState.ScopeInputs(settings)
        settings.transcriptionEngine = .parakeet
        XCTAssertNotEqual(LegacyWhisperModelsState.ScopeInputs(settings), picked)
    }

    func testWithoutAnOldLocationThereIsNoScope() {
        XCTAssertNil(LegacyWhisperModelsState.scope(for: AppSettings(defaults: defaults), legacyBase: nil))
    }

    /// Built once with the engines, not by the Settings view; the App Store
    /// build leaves the row out.
    func testTheEngineControllerBuildsTheStateOnce() {
        let engines = EngineController(settings: AppSettings(defaults: defaults))

        #if APPSTORE
            XCTAssertNil(engines.legacyWhisperModels)
        #else
            XCTAssertNotNil(engines.legacyWhisperModels)
        #endif
    }

    // MARK: - State

    func testRefreshListsWhatIsOnDiskWithNothingTicked() async throws {
        let state = try makeState(makeFixture(variants: [small, base]))
        XCTAssertFalse(state.isVisible)

        await state.refresh()

        XCTAssertEqual(state.models.map(\.variant), [base, small])
        XCTAssertEqual(state.selection, [])
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.syncedToICloud)
        XCTAssertNil(state.failureMessage)
    }

    /// Only the ticked variant goes; the other stays listed.
    func testOnlyTheTickedVariantsGoToTheTrash() async throws {
        let fixture = try makeFixture(variants: [small, base])
        let state = makeState(fixture)
        await state.refresh()

        state.setSelected(small, true)
        XCTAssertEqual(state.selectedModels.map(\.variant), [small])
        await state.moveSelectedToTrash()

        XCTAssertEqual(fixture.trash.trashed, [small])
        XCTAssertEqual(state.models.map(\.variant), [base])
        XCTAssertEqual(state.selection, [])
        XCTAssertFalse(state.isRemoving)
    }

    func testUntickingAndUnlistedNamesLeaveNothingSelected() async throws {
        let state = try makeState(makeFixture(variants: [small]))
        await state.refresh()

        state.setSelected("not-listed", true)
        state.setSelected(small, true)
        state.setSelected(small, false)

        XCTAssertEqual(state.selection, [])
    }

    func testRemovingWithNothingTickedDoesNothing() async throws {
        let fixture = try makeFixture(variants: [small])
        let state = makeState(fixture)
        await state.refresh()

        await state.moveSelectedToTrash()

        XCTAssertEqual(fixture.trash.trashed, [])
    }

    /// The settings are read again before each variant: one that became the
    /// selected model while the first was trashed is not taken.
    func testEachVariantIsCheckedAgainstTheSettingsRightBeforeItGoes() async throws {
        let fixture = try makeFixture(variants: [small, base])
        try makeComplete(small, in: fixture)
        let reads = Box(0)
        let small = small
        let state = LegacyWhisperModelsState(
            scope: {
                reads.value += 1
                // The listing and the first removal see no selection; then small becomes the model.
                return fixture.scope(selected: reads.value <= 2 ? nil : small)
            },
            trash: fixture.trash.callAsFunction,
        )
        await state.refresh()
        state.setSelected(base, true)
        state.setSelected(small, true)

        await state.moveSelectedToTrash()

        XCTAssertEqual(fixture.trash.trashed, [base])
        XCTAssertEqual(state.failures.map(\.item), [small])
    }

    /// A variant whose scope vanishes mid-removal is reported, not silently skipped.
    func testAVariantLeftWithoutAScopeIsReported() async throws {
        let fixture = try makeFixture(variants: [small, base])
        let reads = Box(0)
        let state = LegacyWhisperModelsState(
            scope: {
                reads.value += 1
                return reads.value <= 2 ? fixture.scope() : nil
            },
            trash: fixture.trash.callAsFunction,
        )
        await state.refresh()
        state.setSelected(base, true)
        state.setSelected(small, true)

        await state.moveSelectedToTrash()

        XCTAssertEqual(fixture.trash.trashed, [base])
        XCTAssertEqual(state.failures, [.init(item: small, reason: "The old folder is no longer available.")])
    }

    /// A variant that leaves the list (it just became the selected model) loses
    /// its tick, so the confirmation cannot offer it.
    func testARescanDropsTicksOnVariantsNoLongerListed() async throws {
        let fixture = try makeFixture(variants: [small, base])
        try makeComplete(small, in: fixture)
        let selected = Box<String?>(nil)
        let state = LegacyWhisperModelsState(scope: { fixture.scope(selected: selected.value) }, trash: fixture.trash.callAsFunction)
        await state.refresh()
        state.setSelected(small, true)

        selected.value = small
        await state.refresh()

        XCTAssertEqual(state.models.map(\.variant), [base])
        XCTAssertEqual(state.selection, [])
    }

    /// A model that stayed is still listed, with the reason next to it, until
    /// the pane appears again.
    func testFailuresAreKeptUntilThePaneAppearsAgain() async throws {
        let state = try makeState(makeFixture(variants: [small, base], failing: [small]))
        await state.refresh()
        state.setSelected(small, true)

        await state.moveSelectedToTrash()

        XCTAssertEqual(state.models.map(\.variant), [base, small])
        XCTAssertEqual(state.failures, [.init(item: small, reason: "Permission denied.")])
        XCTAssertEqual(state.failureMessage, LegacyWhisperModelInventory.failureMessage(state.failures))

        // A settings change rescans but keeps the reason; the pane appearing clears it.
        await state.refresh()
        XCTAssertEqual(state.failures.map(\.item), [small])
        state.paneAppeared()
        XCTAssertEqual(state.failures, [])
    }

    /// No `Documents` folder at all: nothing to list.
    func testWithoutAScopeThereIsNothingToList() async {
        let state = LegacyWhisperModelsState { nil }

        await state.refresh()

        XCTAssertEqual(state.models, [])
    }

    /// The settings-bound initializer, pointed at a temp tree: the selected
    /// variant is complete and not yet moved, so only the other one is offered.
    func testTheSettingsBoundStateFollowsTheSettings() async throws {
        let fixture = try makeFixture(variants: [small, base])
        try makeComplete(small, in: fixture)
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitModel = small
        let state = LegacyWhisperModelsState(
            settings: settings,
            legacyBase: fixture.legacyBase,
            currentBase: fixture.currentBase,
            currentRepoRoot: fixture.currentRepoRoot,
            trash: fixture.trash.callAsFunction,
        )

        await state.refresh()
        XCTAssertEqual(state.models.map(\.variant), [base])

        // An incomplete selected variant is no use to the migration, so it goes too.
        settings.whisperKitModel = base
        await state.refresh()
        XCTAssertEqual(state.models.map(\.variant), [base, small])
    }

    // MARK: - View wiring

    func testTheRowIsAbsentWithoutLeftoversOrWithoutAState() async throws {
        let state = try makeState(makeFixture(variants: []))
        await state.refresh()

        XCTAssertThrowsError(try trashButton(in: makeView(state)))
        XCTAssertThrowsError(try trashButton(in: makeView(nil)))
    }

    /// Opening the pane looks at the disk.
    func testThePaneRefreshesWhenItAppears() async throws {
        let state = try makeState(makeFixture(variants: [small]))

        try await makeView(state).inspect().find(ViewType.Form.self).callTask(id: LegacyWhisperModelsState.ScopeInputs(AppSettings(defaults: defaults)))

        XCTAssertEqual(state.models.map(\.variant), [small])
    }

    func testTheRowSaysTheFolderIsShared() async throws {
        let state = try makeState(makeFixture(variants: [small]))
        await state.refresh()

        XCTAssertNoThrow(try makeView(state).inspect().find(text: LegacyWhisperModelInventory.sharedFolderNote))
    }

    func testTickingAVariantSelectsIt() async throws {
        let state = try makeState(makeFixture(variants: [small, base]))
        await state.refresh()

        try toggle(1, in: makeView(state)).tap()

        XCTAssertEqual(state.selection, [small])
        XCTAssertTrue(try toggle(1, in: makeView(state)).isOn())
    }

    func testTheButtonWaitsForATickThenAsksForConfirmation() async throws {
        let fixture = try makeFixture(variants: [small])
        let state = makeState(fixture)
        await state.refresh()
        XCTAssertTrue(try trashButton(in: makeView(state)).isDisabled())

        state.setSelected(small, true)
        let view = makeView(state)
        XCTAssertNoThrow(try view.inspect().find(text: state.summary))
        try trashButton(in: view).tap()

        XCTAssertTrue(state.isConfirming)
        XCTAssertEqual(fixture.trash.trashed, [])
    }

    func testConfirmingMovesTheTickedModelsToTheTrash() async throws {
        let fixture = try makeFixture(variants: [small, base])
        let state = makeState(fixture)
        await state.refresh()
        state.setSelected(small, true)
        state.isConfirming = true

        let dialog = try makeView(state).inspect()
            .find(ViewType.HStack.self) { row in
                (try? row.find(viewWithAccessibilityIdentifier: A11yID.legacyWhisperModelsTrashButton)) != nil
            }
            .confirmationDialog()
        XCTAssertEqual(try dialog.message().text().string(), state.confirmationMessage)
        try dialog.actions().button().tap()

        for _ in 0 ..< 200 where state.models.count == 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fixture.trash.trashed, [small])
        XCTAssertEqual(state.models.map(\.variant), [base])
    }
}

// MARK: - Removal in progress

@MainActor
extension TranscriptionSettingsLegacyModelsTests {
    /// While a removal runs, the model can not be changed, and nothing can be
    /// ticked or trashed a second time.
    func testTheModelControlsAreDisabledWhileARemovalRuns() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try makeFixture(variants: [small], gate: gate)
        let state = makeState(fixture)
        await state.refresh()
        state.setSelected(small, true)
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit

        let removal = Task { await state.moveSelectedToTrash() }
        for _ in 0 ..< 10000 where !state.isRemoving {
            await Task.yield()
        }
        let view = makeView(state, settings: settings)
        let picker = Result { try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.whisperKitModelPicker) }
        let disabled = Result { try (picker.get().isDisabled(), toggle(0, in: view).isDisabled(), trashButton(in: view).isDisabled()) }
        // Released before any assertion can throw: a parked trash holds the
        // migration lock, which other tests in this process take too.
        gate.signal()
        await removal.value
        let (pickerDisabled, toggleDisabled, buttonDisabled) = try disabled.get()
        XCTAssertTrue(pickerDisabled)
        XCTAssertTrue(toggleDisabled)
        XCTAssertTrue(buttonDisabled)

        XCTAssertFalse(try makeView(state, settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.whisperKitModelPicker).isDisabled())
    }

    func testFailuresAreShownInTheRow() async throws {
        let state = try makeState(makeFixture(variants: [small], failing: [small]))
        await state.refresh()
        state.setSelected(small, true)
        await state.moveSelectedToTrash()

        let message = try XCTUnwrap(state.failureMessage)
        XCTAssertNoThrow(try makeView(state).inspect().find(text: message))
    }

    /// An old folder that cannot be read keeps the row, with the reason, rather
    /// than hiding it as if nothing were left.
    func testAnUnreadableOldFolderIsReportedNotHidden() async throws {
        let fixture = try makeFixture(variants: [small])
        let state = makeState(fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.repoRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.repoRoot.path) }

        await state.refresh()

        XCTAssertEqual(state.models, [])
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.scanProblem, "Could not look for old models in Documents: Permission denied.")
        XCTAssertNoThrow(try makeView(state).inspect().find(text: XCTUnwrap(state.scanProblem)))
    }

    /// Appearing clears the last removal's reasons; a settings-driven rescan does not.
    func testThePaneClearsFailuresOnlyWhenItAppears() async throws {
        let state = try makeState(makeFixture(variants: [small], failing: [small]))
        await state.refresh()
        state.setSelected(small, true)
        await state.moveSelectedToTrash()
        XCTAssertFalse(state.failures.isEmpty)

        try makeView(state).inspect().find(ViewType.Form.self).callOnAppear()

        XCTAssertEqual(state.failures, [])
    }
}
