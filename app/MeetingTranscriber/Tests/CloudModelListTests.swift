@testable import MeetingTranscriber
import os
import ViewInspector
import XCTest

/// The cloud Model dropdown: the `/models` fetch and speech filter against
/// `MockURLProtocol`, then one wiring test per state of the row.
@MainActor
final class CloudModelListTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keyAccount: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "CloudModelListTests-\(getpid())-\(UUID().uuidString)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
        // Never the production account: see `AppSettings.apiKeyAccount`.
        keyAccount = "CloudModelListTests-key-\(getpid())-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.redirectHandler = nil
        KeychainHelper.delete(key: keyAccount)
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        keyAccount = nil
        try await super.tearDown()
    }

    private static let groqModels = #"""
    {"object":"list","data":[
      {"id":"llama-3.3-70b-versatile","object":"model"},
      {"id":"whisper-large-v3-turbo","object":"model"},
      {"id":"meta-llama/llama-guard-4-12b","object":"model"},
      {"id":"whisper-large-v3","object":"model"},
      {"id":"playai-tts","object":"model"}
    ]}
    """#

    private static let openAIModels = #"""
    {"object":"list","data":[
      {"id":"gpt-4o","object":"model"},
      {"id":"whisper-1","object":"model"},
      {"id":"gpt-4o-transcribe","object":"model"},
      {"id":"tts-1","object":"model"}
    ]}
    """#

    private func makeSettings() -> AppSettings {
        let settings = AppSettings(defaults: defaults, cloudTranscriptionAPIKeyAccount: keyAccount)
        settings.cloudTranscriptionEnabled = true
        settings.cloudTranscriptionBaseURL = "https://cloud.test/v1"
        settings.cloudTranscriptionAPIKey = "sk-cloud"
        return settings
    }

    /// Answer every request with `status` and `body`, recording each request.
    private func serve(_ body: String, status: Int = 200) -> OSAllocatedUnfairLock<[URLRequest]> {
        let received = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        MockURLProtocol.handler = { request in
            received.withLock { $0.append(request) }
            // swiftlint:disable:next force_unwrapping
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        return received
    }

    private func makeList() -> CloudModelList {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return CloudModelList(session: URLSession(configuration: config))
    }

    private func fetched(_ body: String, status: Int = 200) async -> CloudModelList {
        _ = serve(body, status: status)
        let list = makeList()
        list.fetch(baseURL: "https://cloud.test/v1", apiKey: "sk-cloud")
        await list.task?.value
        return list
    }

    // MARK: - Fetch and filter

    func testGroqListKeepsOnlyTheWhisperModelsWithTheKeyAsBearer() async throws {
        let received = serve(Self.groqModels)
        let list = makeList()
        list.fetch(baseURL: " https://cloud.test/v1 ", apiKey: "sk-cloud")
        XCTAssertTrue(list.isFetching)
        await list.task?.value

        XCTAssertEqual(list.models, ["whisper-large-v3", "whisper-large-v3-turbo"])
        XCTAssertNil(list.failure)
        XCTAssertFalse(list.isFetching)
        let request = try XCTUnwrap(received.withLock { $0 }.first)
        XCTAssertEqual(request.url?.absoluteString, "https://cloud.test/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-cloud")
    }

    func testOpenAIListKeepsWhisperAndTranscribeModels() async {
        let list = await fetched(Self.openAIModels)
        XCTAssertEqual(list.models, ["gpt-4o-transcribe", "whisper-1"])
    }

    func testListWithoutSpeechModelsShowsEveryModel() async {
        let list = await fetched(#"{"data":[{"id":"model-b"},{"id":"model-a"}]}"#)
        XCTAssertEqual(list.models, ["model-a", "model-b"])
    }

    func testFilterMatchesEachMarkerCaseInsensitively() {
        XCTAssertEqual(
            CloudModelList.speechModels(["Whisper-X", "nova-TRANSCRIBE", "my-ASR", "fast-STT", "gpt-4o"]),
            ["Whisper-X", "nova-TRANSCRIBE", "my-ASR", "fast-STT"],
        )
    }

    func testRejectedKeyLeavesNoListAndAFailure() async throws {
        let list = await fetched(#"{"error":{"message":"Invalid API Key"}}"#, status: 401)
        XCTAssertEqual(list.models, [])
        let failure = try XCTUnwrap(list.failure)
        XCTAssertTrue(failure.contains("401"), failure)
    }

    func testRedirectToAnotherHostIsRefused() async throws {
        let received = serve(Self.groqModels)
        let elsewhere = try XCTUnwrap(URL(string: "https://elsewhere.test/v1/models"))
        MockURLProtocol.redirectHandler = { request in
            request.url?.host == "cloud.test" ? (307, elsewhere) : nil
        }
        let list = makeList()
        list.fetch(baseURL: "https://cloud.test/v1", apiKey: "sk-cloud")
        await list.task?.value

        XCTAssertTrue(received.withLock { $0 }.isEmpty, "nothing may reach the other host")
        XCTAssertEqual(list.models, [])
        XCTAssertNotNil(list.failure)
    }

    /// A fetch from the endpoint the user has since replaced must not fill
    /// the new endpoint's list.
    func testAFetchAnsweredAfterAnInvalidateIsDropped() async {
        _ = serve(Self.groqModels)
        let list = makeList()
        list.fetch(baseURL: "https://cloud.test/v1", apiKey: "sk-cloud")
        list.invalidate()
        await list.task?.value

        XCTAssertEqual(list.models, [])
        XCTAssertFalse(list.isFetching)
    }

    func testAConnectionTestAnsweredAfterAnInvalidateIsDropped() async {
        _ = serve(Self.groqModels)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let test = CloudConnectionTest(session: URLSession(configuration: sessionConfig))
        test.run(CloudTranscriptionConfiguration(baseURL: "https://cloud.test/v1", model: "m", apiKey: "k"))
        test.invalidate()
        await test.task?.value

        XCTAssertNil(test.result)
        XCTAssertFalse(test.isRunning)
    }

    // MARK: - Model row wiring

    private static func drafts(_ settings: AppSettings) -> CloudEndpointDrafts {
        let drafts = CloudEndpointDrafts()
        drafts.load(from: settings)
        return drafts
    }

    func testModelRowIsATextFieldUntilAListArrivesThenADropdown() async throws {
        let settings = makeSettings()
        let list = makeList()
        let row = CloudModelRow(settings: settings, drafts: Self.drafts(settings), modelList: list)
        XCTAssertNoThrow(try row.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField))
        XCTAssertThrowsError(try row.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelPicker))

        _ = serve(Self.groqModels)
        try row.inspect().find(ViewType.Group.self).callOnAppear()
        await list.task?.value

        let picker = try row.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelPicker)
            .find(ViewType.Picker.self)
        try picker.select(value: CloudModelChoice.listed("whisper-large-v3-turbo"))
        XCTAssertEqual(settings.cloudTranscriptionModel, "whisper-large-v3-turbo")
        XCTAssertThrowsError(
            try row.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField),
            "a listed model hides the text field",
        )
    }

    func testFailedFetchKeepsTheTextFieldAndShowsTheFailure() async throws {
        let settings = makeSettings()
        let list = await fetched("", status: 401)
        let row = CloudModelRow(settings: settings, drafts: Self.drafts(settings), modelList: list)

        XCTAssertNoThrow(try row.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField))
        let failure = try row.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelsFailure)
            .text()
            .string()
        XCTAssertEqual(failure, list.failure)
    }

    func testCustomShowsTheTextFieldForAnyID() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionModel = "whisper-large-v3"
        let list = await fetched(Self.groqModels)
        let row = CloudModelRow(settings: settings, drafts: Self.drafts(settings), modelList: list)

        try row.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelPicker)
            .find(ViewType.Picker.self)
            .select(value: CloudModelChoice.custom)
        XCTAssertEqual(settings.cloudTranscriptionModel, "whisper-large-v3", "Custom… alone changes nothing")
        try row.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField)
            .find(ViewType.TextField.self)
            .setInput("distil-whisper-large-v3-en")

        XCTAssertEqual(settings.cloudTranscriptionModel, "distil-whisper-large-v3-en")
    }

    func testUnlistedSavedModelShowsAsCustomUnchanged() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionModel = "my-private-model"
        let list = await fetched(Self.groqModels)
        let row = CloudModelRow(settings: settings, drafts: Self.drafts(settings), modelList: list)

        let selected = try row.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelPicker)
            .find(ViewType.Picker.self)
            .selectedValue(CloudModelChoice.self)
        XCTAssertEqual(selected, .custom)
        let field = try row.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField)
            .find(ViewType.TextField.self)
        XCTAssertEqual(try field.input(), "my-private-model")
        XCTAssertEqual(settings.cloudTranscriptionModel, "my-private-model")
    }

    func testSavedListedModelShowsAsSelectedWithoutTheField() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionModel = "whisper-large-v3"
        let list = await fetched(Self.groqModels)
        let row = try CloudModelRow(settings: settings, drafts: Self.drafts(settings), modelList: list).inspect()

        let selected = try row.find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelPicker)
            .find(ViewType.Picker.self)
            .selectedValue(CloudModelChoice.self)
        XCTAssertEqual(selected, .listed("whisper-large-v3"))
        XCTAssertThrowsError(try row.find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField))
    }

    func testCustomFieldIsLabelledModelIDNotASecondModel() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionModel = "my-private-model"
        let list = await fetched(Self.groqModels)
        let row = try CloudModelRow(settings: settings, drafts: Self.drafts(settings), modelList: list).inspect()

        let picker = try row.find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelPicker)
            .find(ViewType.Picker.self)
        XCTAssertEqual(try picker.labelView().text().string(), "Model")
        let field = try row.find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField)
            .find(ViewType.TextField.self)
        XCTAssertEqual(try field.labelView().text().string(), "Model ID")
    }

    func testRefreshButtonRefetches() async throws {
        let settings = makeSettings()
        let received = serve(Self.groqModels)
        let list = makeList()
        let row = CloudModelRow(settings: settings, drafts: Self.drafts(settings), modelList: list)
        let button = { try row.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionFetchModelsButton) }
        XCTAssertEqual(try button().find(ViewType.Text.self).string(), "Fetch Models")

        try button().find(ViewType.Button.self).tap()
        await list.task?.value
        XCTAssertEqual(try button().find(ViewType.Text.self).string(), "Refresh Models")
        try button().find(ViewType.Button.self).tap()
        await list.task?.value

        XCTAssertEqual(received.withLock { $0 }.count, 2)
    }

    func testDirtyDraftsSuppressAutomaticFetchAfterSwitchingFromLocalToCloud() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionConsented = true
        let received = serve(Self.groqModels)
        let list = makeList()
        let view = TranscriptionSettingsView(
            settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine(), cloudModelList: list,
        )
        let appear = {
            try view.inspect().find(CloudModelRow.self).actualView().inspect().find(ViewType.Group.self).callOnAppear()
        }
        try appear()
        await list.task?.value
        let savedHost = "cloud.test"
        XCTAssertEqual(received.withLock { $0.compactMap { $0.url?.host } }, [savedHost])

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionBaseURLField)
            .find(ViewType.TextField.self).setInput("https://draft.test/v1")
        let method = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.transcriptionMethodPicker)
            .find(ViewType.Picker.self)
        try method.select(value: TranscriptionMethod.onThisMac)
        XCTAssertThrowsError(try view.inspect().find(CloudModelRow.self))
        try method.select(value: TranscriptionMethod.cloud)
        try appear()
        await list.task?.value
        XCTAssertEqual(received.withLock { $0.compactMap { $0.url?.host } }, [savedHost])

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionFetchModelsButton)
            .find(ViewType.Button.self).tap()
        await list.task?.value
        XCTAssertEqual(received.withLock { $0.compactMap { $0.url?.host } }, [savedHost, "draft.test"])
    }

    func testNoAutomaticFetchWithoutAKey() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionAPIKey = ""
        let received = serve(Self.groqModels)
        let list = makeList()

        try CloudModelRow(settings: settings, drafts: Self.drafts(settings), modelList: list).inspect().find(ViewType.Group.self).callOnAppear()

        XCTAssertFalse(list.isFetching)
        XCTAssertNil(list.task)
        XCTAssertTrue(received.withLock { $0 }.isEmpty)
    }
}
