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
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeView(settings: AppSettings) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
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

    func testRepositoryAndVariantFieldsWriteBack() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        let view = makeView(settings: settings)

        try view.inspect().find(ViewType.TextField.self) { try $0.accessibilityIdentifier() == A11yID.whisperKitCustomRepoField }
            .setInput("spert/flix-swissgerman-whisperkit")
        try view.inspect().find(ViewType.TextField.self) { try $0.accessibilityIdentifier() == A11yID.whisperKitCustomVariantField }
            .setInput("flix-swissgerman-large-v3_8bit")

        XCTAssertEqual(settings.whisperKitCustomRepo, "spert/flix-swissgerman-whisperkit")
        XCTAssertEqual(settings.whisperKitCustomVariant, "flix-swissgerman-large-v3_8bit")
    }

    func testFolderFieldWritesBackThroughTheBookmarkSafeSetter() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true

        try makeView(settings: settings).inspect()
            .find(ViewType.TextField.self) { try $0.accessibilityIdentifier() == A11yID.whisperKitCustomModelFolderField }
            .setInput("/tmp/typed-model")

        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, "/tmp/typed-model")
        XCTAssertNil(settings.whisperKitCustomModelFolderBookmark)
    }
}
