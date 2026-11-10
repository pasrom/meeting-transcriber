import AppKit
@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The meeting-notes API keys are Keychain items. Typing into their fields must
/// stay in a draft and reach the Keychain once, when the field is left, so a
/// half-typed key is never what a job that starts meanwhile reads. The commit
/// triggers of the field itself are pinned in `DraftTextFieldTests`; these pin
/// the drafts object and that each field is wired to its own key.
@MainActor
final class ProtocolAPIKeyDraftsTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var apiKeyAccount: String!
    private var claudeAPIKeyAccount: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        let unique = "\(getpid())-\(UUID().uuidString)"
        suiteName = "ProtocolAPIKeyDraftsTests-\(unique)"
        apiKeyAccount = "ProtocolAPIKeyDraftsTests-openAIAPIKey-\(unique)"
        claudeAPIKeyAccount = "ProtocolAPIKeyDraftsTests-claudeAPIKey-\(unique)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
    }

    override func tearDown() async throws {
        KeychainHelper.delete(key: apiKeyAccount)
        KeychainHelper.delete(key: claudeAPIKeyAccount)
        DefaultsSuite.remove(suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount, claudeAPIKeyAccount: claudeAPIKeyAccount)
    }

    private func closeNotification(ofWindow id: String) -> Notification {
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(id)
        return Notification(name: NSWindow.willCloseNotification, object: window)
    }

    // MARK: - Drafts

    func testDraftsStartFromTheStoredKeys() {
        let settings = makeSettings()
        settings.openAIAPIKey = "sk-stored"

        let drafts = ProtocolAPIKeyDrafts(settings: settings)

        XCTAssertEqual(drafts.openAI, "sk-stored")
        XCTAssertEqual(drafts.savedOpenAI, "sk-stored")
    }

    /// Closing the Settings window only hides it, so neither a focus change nor
    /// `onDisappear` reaches the field, and a key typed but never confirmed would
    /// stay in the field while the Keychain kept the old one.
    func testClosingTheSettingsWindowCommitsAnEditedKey() {
        let settings = makeSettings()
        let drafts = ProtocolAPIKeyDrafts(settings: settings)
        drafts.openAI = "sk-typed"

        drafts.settingsWindowWillClose(closeNotification(ofWindow: "settings"), settings: settings)

        XCTAssertEqual(settings.openAIAPIKey, "sk-typed")
        XCTAssertEqual(drafts.savedOpenAI, "sk-typed")
    }

    func testClosingAnotherWindowCommitsNothing() {
        let settings = makeSettings()
        let drafts = ProtocolAPIKeyDrafts(settings: settings)
        drafts.openAI = "sk-typed"

        drafts.settingsWindowWillClose(closeNotification(ofWindow: "speaker-naming"), settings: settings)

        XCTAssertEqual(settings.openAIAPIKey, "")
    }

    /// An unchanged draft must not be written: clearing an empty draft would be
    /// a Keychain delete, and a write re-runs the settings observers.
    func testCommitPendingLeavesAnUnchangedKeyAlone() {
        let settings = makeSettings()
        settings.openAIAPIKey = "sk-stored"
        let drafts = ProtocolAPIKeyDrafts(settings: settings)
        settings.openAIAPIKey = "sk-changed-elsewhere"

        drafts.commitPending(to: settings)

        XCTAssertEqual(settings.openAIAPIKey, "sk-changed-elsewhere")
    }

    // MARK: - Field wiring (one per control)

    private func secureField(
        _ identifier: String, in view: OutputSettingsView,
    ) throws -> InspectableView<ViewType.SecureField> {
        try view.inspect()
            .find(DraftTextField.self) { try $0.accessibilityIdentifier() == identifier }
            .find(ViewType.SecureField.self)
    }

    func testOpenAIKeyFieldKeepsTypingInTheDraftAndCommitsOnSubmit() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        let drafts = ProtocolAPIKeyDrafts(settings: settings)
        let view = OutputSettingsView(settings: settings, apiKeyDrafts: drafts)
        let field = try secureField(A11yID.openAIAPIKeyField, in: view)

        try field.setInput("sk-half")
        XCTAssertEqual(settings.openAIAPIKey, "", "a keystroke must not reach the Keychain")
        XCTAssertEqual(drafts.openAI, "sk-half")

        try field.callOnSubmit()
        XCTAssertEqual(settings.openAIAPIKey, "sk-half")
    }

    #if !APPSTORE
        func testClaudeKeyFieldKeepsTypingInTheDraftAndCommitsOnSubmit() throws {
            let settings = makeSettings()
            settings.protocolProvider = .claudeCLI
            let drafts = ProtocolAPIKeyDrafts(settings: settings)
            let view = OutputSettingsView(settings: settings, apiKeyDrafts: drafts)
            let field = try secureField(A11yID.claudeAPIKeyField, in: view)

            try field.setInput("sk-ant-half")
            XCTAssertEqual(settings.claudeAPIKey, "", "a keystroke must not reach the Keychain")
            XCTAssertEqual(drafts.claude, "sk-ant-half")

            try field.callOnSubmit()
            XCTAssertEqual(settings.claudeAPIKey, "sk-ant-half")
            XCTAssertEqual(settings.openAIAPIKey, "", "each field commits to its own key")
        }
    #endif
}
