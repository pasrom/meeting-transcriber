@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// What drops a Test Connection result, and where pending endpoint edits are
/// saved; split from `TranscriptionSettingsCloudTests` at its length limit.
@MainActor
final class TranscriptionSettingsCloudEndpointTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keyAccount: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsCloudEndpointTests-\(getpid())-\(UUID().uuidString)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
        keyAccount = "TranscriptionSettingsCloudEndpointTests-key-\(getpid())-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        KeychainHelper.delete(key: keyAccount + ".alternate")
        KeychainHelper.delete(key: keyAccount)
        DefaultsSuite.remove(suiteName)
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, cloudTranscriptionAPIKeyAccount: keyAccount)
    }

    /// Test Connection sends the model and language too, so a result from
    /// before either changed says nothing about the new one.
    func testChangingTheLanguageOrModelDropsTheConnectionResult() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        settings.cloudTranscriptionLanguage = "en"
        settings.cloudTranscriptionBaseURL = "https://cloud.test/v1"
        MockURLProtocol.handler = { request in
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"segments":[]}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let test = CloudConnectionTest(session: URLSession(configuration: sessionConfig))
        let drafts = CloudEndpointDrafts()
        drafts.load(from: settings)
        let controls = CloudTranscriptionControls(
            settings: settings, drafts: drafts, connectionTest: test, modelList: CloudModelList(), localFallback: "",
        )
        test.run(drafts.configuration(from: settings))
        await test.task?.value
        XCTAssertEqual(test.result, .success, "test premise")

        try controls.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionLanguagePicker)
            .picker()
            .select(value: "fr")
        XCTAssertEqual(settings.cloudTranscriptionLanguage, "fr")
        XCTAssertNil(test.result, "a language change kept the old result")

        test.run(drafts.configuration(from: settings))
        await test.task?.value
        XCTAssertEqual(test.result, .success, "test premise")
        try controls.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField)
            .find(ViewType.TextField.self)
            .setInput("whisper-large-v3")
        XCTAssertNil(test.result, "a model change kept the old result")
    }

    func testSelectingADifferentListedModelDropsTheConnectionResult() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionBaseURL = "https://cloud.test/v1"
        settings.cloudTranscriptionModel = "whisper-first"
        MockURLProtocol.handler = { request in
            let body = request.url?.lastPathComponent == "models"
                ? #"{"data":[{"id":"whisper-first"},{"id":"whisper-second"}]}"#
                : #"{"segments":[]}"#
            // swiftlint:disable:next force_unwrapping
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let list = CloudModelList(session: session)
        let test = CloudConnectionTest(session: session)
        let drafts = CloudEndpointDrafts()
        drafts.load(from: settings)
        let controls = CloudTranscriptionControls(
            settings: settings, drafts: drafts, connectionTest: test, modelList: list, localFallback: "",
        )
        list.fetch(baseURL: drafts.baseURL, apiKey: drafts.apiKey)
        await list.task?.value
        test.run(drafts.configuration(from: settings))
        await test.task?.value
        XCTAssertEqual(test.result, .success)

        try controls.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelPicker)
            .find(ViewType.Picker.self).select(value: CloudModelChoice.listed("whisper-second"))
        XCTAssertEqual(settings.cloudTranscriptionModel, "whisper-second")
        XCTAssertNil(test.result)
    }

    func testClosingSettingsKeepsAnOriginChangeWithAnUneditedKeyUnsaved() {
        let settings = makeSettings()
        settings.cloudTranscriptionBaseURL = "https://old.test/v1"
        settings.cloudTranscriptionAPIKey = "sk-old"
        let drafts = CloudEndpointDrafts()
        drafts.load(from: settings)
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(Notification.settingsWindowID)
        let close = Notification(name: NSWindow.willCloseNotification, object: window)
        for url in ["https://new.test/v1", "http://old.test/v1", "https://old.test:8443/v1"] {
            drafts.baseURL = url
            drafts.settingsWindowWillClose(close, settings: settings)
            XCTAssertEqual(settings.cloudTranscriptionBaseURL, "https://old.test/v1")
            XCTAssertTrue(drafts.hasChanges)
        }

        drafts.baseURL = "https://OLD.test:443/v2"
        drafts.settingsWindowWillClose(close, settings: settings)
        XCTAssertEqual(settings.cloudTranscriptionBaseURL, drafts.baseURL)
        XCTAssertFalse(drafts.hasChanges)
    }

    func testClosingSettingsSavesAnOriginChangeWhenNoKeyIsSaved() {
        let settings = makeSettings()
        settings.cloudTranscriptionBaseURL = "https://old.test/v1"
        settings.cloudTranscriptionAPIKey = ""
        let drafts = CloudEndpointDrafts()
        drafts.load(from: settings)
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(Notification.settingsWindowID)
        drafts.baseURL = "http://localhost:8000/v1"

        drafts.settingsWindowWillClose(Notification(name: NSWindow.willCloseNotification, object: window), settings: settings)

        XCTAssertEqual(settings.cloudTranscriptionBaseURL, "http://localhost:8000/v1")
        XCTAssertFalse(drafts.hasChanges)
    }

    func testSettingsWindowSavesDraftsAfterLeavingTheTranscriptionTab() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        settings.cloudTranscriptionBaseURL = "https://old.test/v1"
        let root = NSHostingView(rootView: SettingsView(
            settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine(),
            recognitionStatsLog: RecognitionStatsLog(), stageTimingLog: StageTimingLog(),
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(Notification.settingsWindowID)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let sidebar = { root.descendants(of: NSTableView.self).first { $0.numberOfRows == 7 } }
        pump { sidebar() != nil }
        let table = try XCTUnwrap(sidebar())
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let urlField = { root.descendants(of: NSTextField.self).first { $0.stringValue == "https://old.test/v1" } }
        pump { urlField() != nil }
        try type("https://new.test/v1", into: XCTUnwrap(urlField()), in: window)
        try type("sk-new", into: XCTUnwrap(root.descendants(of: NSSecureTextField.self).first), in: window)

        settings.cloudTranscriptionEnabled = false
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pump { root.descendants(of: NSSecureTextField.self).isEmpty }
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(settings.cloudTranscriptionBaseURL, "https://old.test/v1")

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        pump { settings.cloudTranscriptionBaseURL == "https://new.test/v1" }
        XCTAssertEqual(settings.cloudTranscriptionBaseURL, "https://new.test/v1")
        XCTAssertEqual(settings.cloudTranscriptionAPIKey, "sk-new")
    }

    private func type(_ text: String, into field: NSTextField, in window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        XCTAssertTrue(window.makeFirstResponder(nil))
    }
}
