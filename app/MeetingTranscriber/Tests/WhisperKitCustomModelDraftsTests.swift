@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The drafts behind the custom WhisperKit model fields. Which edit "Load Model"
/// hands over is pinned through the view in `TranscriptionSettingsCustomModelTests`;
/// these tests pin what the view test cannot reach.
@MainActor
final class WhisperKitCustomModelDraftsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "WhisperKitCustomModelDraftsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    /// The drafts are filled from the settings only when the fields appear, which
    /// they do only while the custom model is on. A draft that was never filled is
    /// empty, and handing it over would erase the repository the user entered.
    func testNothingIsHandedOverWhileTheCustomModelIsOff() {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        settings.whisperKitCustomModelEnabled = false

        WhisperKitCustomModelDrafts().commitPending(to: settings)

        XCTAssertEqual(settings.whisperKitCustomRepo, "spert/flix-swissgerman-whisperkit")
        XCTAssertEqual(settings.whisperKitCustomVariant, "flix-swissgerman-large-v3_8bit")
    }

    /// Picking the folder that is already set leaves the setting as it was, so the
    /// field does not reset itself, and an edit typed before would stay in it. The
    /// next focus loss would then commit that edit through the path setter, which
    /// drops the bookmark the pick has just made.
    func testChoosingTheSameFolderAgainDropsAnUncommittedEdit() throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        let picked = try makeTempDirectory(prefix: "wk-picked")
        settings.setWhisperKitCustomModelFolder(picked)
        let drafts = WhisperKitCustomModelDrafts()
        drafts.folder = "/a-typo"

        drafts.chooseFolder(picked, in: settings)
        XCTAssertEqual(drafts.folder, settings.whisperKitCustomModelFolderPath)

        // What the field does when it loses focus.
        let field = DraftTextField("Or model folder", value: settings.whisperKitCustomModelFolderPath, draft: Bindable(drafts).folder) { path in
            settings.setWhisperKitCustomModelFolderPath(path)
        }
        try field.inspect().find(ViewType.TextField.self).callOnChange(oldValue: true, newValue: false)

        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, picked.path)
        XCTAssertNotNil(settings.whisperKitCustomModelFolderBookmark, "The bookmark of the pick must survive")
    }

    /// Closing the Settings window only hides it, so no focus change and no
    /// `onDisappear` reach the fields. A value typed and never confirmed would stay in
    /// the field while the settings, and with them the engine, kept the old one.
    func testClosingTheSettingsWindowHandsOverAnUncommittedEdit() {
        let settings = whisperKitSettings()
        let drafts = WhisperKitCustomModelDrafts()
        drafts.repo = "spert/other-whisperkit"

        drafts.settingsWindowWillClose(closeNotification(ofWindow: "settings"), settings: settings)

        XCTAssertEqual(settings.whisperKitCustomRepo, "spert/other-whisperkit")
    }

    /// Every window of the app posts the same notification; the naming window or
    /// the app picker closing says nothing about the Settings fields.
    func testClosingAnotherWindowHandsNothingOver() {
        let settings = whisperKitSettings()
        let drafts = WhisperKitCustomModelDrafts()
        drafts.repo = "spert/other-whisperkit"

        drafts.settingsWindowWillClose(closeNotification(ofWindow: "speaker-naming"), settings: settings)

        XCTAssertEqual(settings.whisperKitCustomRepo, "spert/flix-swissgerman-whisperkit")
    }

    /// The fields are shown only for WhisperKit, so with Parakeet selected the
    /// drafts were never filled from the settings. A close then would hand over
    /// empty strings and erase the repository the user entered earlier.
    func testNothingIsHandedOverWhileParakeetIsSelected() {
        let settings = whisperKitSettings()
        settings.transcriptionEngine = .parakeet

        WhisperKitCustomModelDrafts().settingsWindowWillClose(closeNotification(ofWindow: "settings"), settings: settings)

        XCTAssertEqual(settings.whisperKitCustomRepo, "spert/flix-swissgerman-whisperkit")
        XCTAssertEqual(settings.whisperKitCustomVariant, "flix-swissgerman-large-v3_8bit")
    }

    /// Settings with the custom model on and WhisperKit selected, the state in
    /// which the fields are shown.
    private func whisperKitSettings() -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        return settings
    }

    private func closeNotification(ofWindow id: String) -> Notification {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        return Notification(name: NSWindow.willCloseNotification, object: window)
    }
}
