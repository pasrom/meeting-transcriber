@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the custom WhisperKit model controls. The resolution behind them is
/// pinned in `WhisperKitCustomModelSettingsTests`.
@MainActor
final class TranscriptionSettingsCustomModelTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsCustomModelTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeView(settings: AppSettings, whisperKitEngine: WhisperKitEngine = WhisperKitEngine()) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: whisperKitEngine,
            parakeetEngine: ParakeetEngine(),
        )
    }

    private func modelPicker(in view: TranscriptionSettingsView) throws -> InspectableView<ViewType.Picker> {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.whisperKitModelPicker)
            .find(ViewType.Picker.self)
    }

    /// Picking the custom entry must keep the stock variant, which is what an
    /// unfinished custom model falls back to.
    func testPickingTheCustomEntryKeepsTheStockVariant() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitModel = "openai_whisper-small"

        try modelPicker(in: makeView(settings: settings)).select(value: TranscriptionSettingsView.customModelTag)

        XCTAssertTrue(settings.whisperKitCustomModelEnabled)
        XCTAssertEqual(settings.whisperKitModel, "openai_whisper-small")
    }

    /// `select(value:)` writes the binding without checking that the value is one
    /// of the picker's options, so the entry's presence and its tag are pinned here.
    func testThePickerOffersTheCustomEntryUnderItsTag() throws {
        let picker = try modelPicker(in: makeView(settings: AppSettings(defaults: defaults)))

        let entry = try picker.find(text: "Custom model\u{2026}")

        XCTAssertEqual(try entry.tag(), AnyHashable(TranscriptionSettingsView.customModelTag))
    }

    func testThePickerShowsTheCustomEntryWhileTheCustomModelIsOn() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitModel = "openai_whisper-small"

        settings.whisperKitCustomModelEnabled = true
        XCTAssertEqual(
            try modelPicker(in: makeView(settings: settings)).selectedValue(String.self),
            TranscriptionSettingsView.customModelTag,
        )

        settings.whisperKitCustomModelEnabled = false
        XCTAssertEqual(try modelPicker(in: makeView(settings: settings)).selectedValue(String.self), "openai_whisper-small")
    }

    func testPickingAStockVariantTurnsTheCustomModelOff() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true

        try modelPicker(in: makeView(settings: settings)).select(value: "openai_whisper-base")

        XCTAssertFalse(settings.whisperKitCustomModelEnabled)
        XCTAssertEqual(settings.whisperKitModel, "openai_whisper-base")
    }

    func testCustomFieldsAppearOnlyForTheCustomEntry() throws {
        let settings = AppSettings(defaults: defaults)
        XCTAssertThrowsError(
            try makeView(settings: settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.whisperKitCustomRepoField),
        )

        settings.whisperKitCustomModelEnabled = true

        let view = makeView(settings: settings)
        for identifier in [
            A11yID.whisperKitCustomRepoField,
            A11yID.whisperKitCustomVariantField,
            A11yID.whisperKitCustomModelFolderField,
        ] {
            XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: identifier), identifier)
        }
    }

    /// The field carrying `identifier`, as the draft-editing component it is.
    private func draftField(_ identifier: String, in view: TranscriptionSettingsView) throws -> DraftTextField {
        try view.inspect()
            .find(DraftTextField.self) { try $0.accessibilityIdentifier() == identifier }
            .actualView()
    }

    /// The text field inside the component carrying `identifier`, which is where
    /// typing lands.
    private func textField(_ identifier: String, in view: TranscriptionSettingsView) throws -> InspectableView<ViewType.TextField> {
        try view.inspect()
            .find(DraftTextField.self) { try $0.accessibilityIdentifier() == identifier }
            .find(ViewType.TextField.self)
    }

    /// Every keystroke used to be written straight into the settings, which the
    /// engine observer acts on at once: a valid-looking intermediate value dropped
    /// the loaded model, and a recording starting meanwhile loaded a half-typed
    /// one. Typing now stays in the field; the settings hear the value on commit.
    func testTypingInTheRepositoryAndVariantFieldsDoesNotReachSettings() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        let view = makeView(settings: settings)

        try textField(A11yID.whisperKitCustomRepoField, in: view).setInput("spert/flix-swissgerman-whisperkit-v2")
        try textField(A11yID.whisperKitCustomVariantField, in: view).setInput("flix-swissgerman-large-v3_8bit-v2")

        XCTAssertEqual(settings.whisperKitCustomRepo, "spert/flix-swissgerman-whisperkit")
        XCTAssertEqual(settings.whisperKitCustomVariant, "flix-swissgerman-large-v3_8bit")
    }

    func testCommittingTheRepositoryAndVariantFieldsWritesBack() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        let view = makeView(settings: settings)

        try draftField(A11yID.whisperKitCustomRepoField, in: view).commit("spert/flix-swissgerman-whisperkit")
        try draftField(A11yID.whisperKitCustomVariantField, in: view).commit("flix-swissgerman-large-v3_8bit")

        XCTAssertEqual(settings.whisperKitCustomRepo, "spert/flix-swissgerman-whisperkit")
        XCTAssertEqual(settings.whisperKitCustomVariant, "flix-swissgerman-large-v3_8bit")
    }

    func testTypingInTheFolderFieldDoesNotReachSettings() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        let view = makeView(settings: settings)

        try textField(A11yID.whisperKitCustomModelFolderField, in: view).setInput("/tmp/typed-model")

        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, "")
    }

    /// A bookmark is tied to the folder it was made for, so a typed path has to
    /// go through the setter that drops it; the bookmark is seeded first because
    /// otherwise a nil afterwards proves nothing.
    func testCommittingTheFolderFieldWritesBackThroughTheBookmarkSafeSetter() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        try settings.setWhisperKitCustomModelFolder(makeTempDirectory(prefix: "wk-picked"))
        XCTAssertNotNil(settings.whisperKitCustomModelFolderBookmark, "Precondition: a picked folder carries a bookmark")

        try draftField(A11yID.whisperKitCustomModelFolderField, in: makeView(settings: settings)).commit("/tmp/typed-model")

        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, "/tmp/typed-model")
        XCTAssertNil(settings.whisperKitCustomModelFolderBookmark)
    }

    /// What appearing on screen does to each field: its draft starts from the
    /// setting it edits.
    private func showCustomFields(in view: TranscriptionSettingsView) throws {
        for identifier in [
            A11yID.whisperKitCustomRepoField,
            A11yID.whisperKitCustomVariantField,
            A11yID.whisperKitCustomModelFolderField,
        ] {
            try textField(identifier, in: view).callOnAppear()
        }
    }

    /// Clicking "Load Model" need not take focus from the field being edited, and
    /// the button reads the selection from the settings. Without handing over the
    /// pending edit first it loaded the model the field no longer showed.
    func testLoadModelHandsOverAnEditTheFieldHasNotCommitted() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        let engine = WhisperKitEngine()
        // The load the button starts must not reach the Hub.
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            makePipe: { _, _ in throw WhisperKitModelError.folderNotLoadable },
        ))
        let view = makeView(settings: settings, whisperKitEngine: engine)
        try showCustomFields(in: view)

        try textField(A11yID.whisperKitCustomRepoField, in: view).setInput("spert/other-whisperkit")
        try view.inspect().find(button: "Load Model").tap()

        XCTAssertEqual(settings.whisperKitCustomRepo, "spert/other-whisperkit")
        XCTAssertEqual(settings.whisperKitCustomVariant, "flix-swissgerman-large-v3_8bit", "An unedited field is left alone")
        XCTAssertEqual(engine.modelOrigin, .hub(repoID: "spert/other-whisperkit"), "The load is for the edited repository")
        XCTAssertEqual(engine.modelVariant, "flix-swissgerman-large-v3_8bit")
    }

    /// Clear writes an empty path, and the field has to show that rather than a
    /// path typed before and never committed.
    func testClearAlsoDropsAnUncommittedFolderEdit() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        try settings.setWhisperKitCustomModelFolder(makeTempDirectory(prefix: "wk-picked"))
        let view = makeView(settings: settings)
        try showCustomFields(in: view)

        try textField(A11yID.whisperKitCustomModelFolderField, in: view).setInput("/a-typo")
        try view.inspect().find(button: "Clear").tap()

        XCTAssertEqual(try textField(A11yID.whisperKitCustomModelFolderField, in: view).input(), "")
    }

    /// The status line is where the user looks when "Load Model" comes back; the
    /// reason the load failed belongs next to it, not only in a redacted log line.
    func testTheStatusLineShowsWhyTheLastLoadFailed() async throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        let engine = WhisperKitEngine()
        engine.applyModelVariant("finetune", origin: .localFolder(path: "/picked/finetune", bookmark: nil))
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in throw WhisperKitModelError.folderIncomplete(missing: "tokenizer.json") },
            makePipe: { _, _ in throw WhisperKitModelError.folderNotLoadable },
        ))
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .unloaded, "Precondition: the load failed")

        let view = makeView(settings: settings, whisperKitEngine: engine)

        XCTAssertNoThrow(try view.inspect().find(text: "Model folder is missing tokenizer.json."))
    }

    func testClearForgetsThePickedFolderAtOnce() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        try settings.setWhisperKitCustomModelFolder(makeTempDirectory(prefix: "wk-picked"))

        try makeView(settings: settings).inspect().find(button: "Clear").tap()

        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, "")
        XCTAssertNil(settings.whisperKitCustomModelFolderBookmark)
    }
}
