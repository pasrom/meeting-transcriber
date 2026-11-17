import Foundation
@testable import MeetingTranscriber
import XCTest

/// Saved OpenAI-compatible connections (Settings → Output → AI Provider): the live
/// `openAI*` settings and the API key follow the selected connection, each
/// connection keeps its own Keychain item, and the list survives a relaunch.
final class AppSettingsOpenAIConnectionsTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var apiKeyAccount: String!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        let unique = "\(getpid())-\(UUID().uuidString)"
        suiteName = "AppSettingsOpenAIConnectionsTests-\(unique)"
        apiKeyAccount = "AppSettingsOpenAIConnectionsTests-openAIAPIKey-\(unique)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
    }

    override func tearDown() async throws {
        for connection in settings?.openAIConnections ?? [] {
            KeychainHelper.delete(key: settings.openAIKeyAccount(for: connection))
        }
        KeychainHelper.delete(key: apiKeyAccount)
        settings = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
    }

    func testExistingSetupBecomesTheDefaultConnectionAndKeepsItsKey() throws {
        defaults.set("https://work.example/v1", forKey: "openAIEndpoint")
        defaults.set("gpt-work", forKey: "openAIModel")
        defaults.set(0.4, forKey: "openAITemperature")
        defaults.set(0.6, forKey: "openAITopP")
        defaults.set("customHeader", forKey: "openAIAPIKeyPlacement")
        defaults.set("x-work-key", forKey: "openAIAPIKeyHeaderName")
        KeychainHelper.save(key: apiKeyAccount, value: "sk-existing")
        settings = makeSettings()

        let only = try XCTUnwrap(settings.openAIConnections.first)
        XCTAssertEqual(settings.openAIConnections.count, 1)
        XCTAssertEqual(only.name, "Default")
        XCTAssertEqual(only.endpoint, "https://work.example/v1")
        XCTAssertEqual(only.model, "gpt-work")
        XCTAssertEqual(only.temperature, 0.4)
        XCTAssertEqual(only.topP, 0.6)
        XCTAssertEqual(only.apiKeyPlacement, .customHeader)
        XCTAssertEqual(only.apiKeyHeaderName, "x-work-key")
        XCTAssertEqual(settings.activeOpenAIConnectionID, only.id)
        XCTAssertEqual(settings.openAIAPIKey, "sk-existing")
    }

    func testAddedConnectionCopiesTheSettingsButNotTheKey() {
        settings = makeSettings()
        settings.openAIEndpoint = "https://work.example/v1"
        settings.openAIAPIKey = "sk-work"

        settings.addOpenAIConnection()

        XCTAssertEqual(settings.openAIConnections.count, 2)
        XCTAssertEqual(settings.activeOpenAIConnection?.name, "Connection 2")
        XCTAssertEqual(settings.openAIEndpoint, "https://work.example/v1")
        XCTAssertEqual(settings.openAIAPIKey, "")
    }

    func testSelectingAConnectionRestoresItsSettingsAndKey() {
        settings = makeSettings()
        let work = settings.activeOpenAIConnectionID
        settings.openAIEndpoint = "https://work.example/v1"
        settings.openAIModel = "gpt-work"
        settings.openAITemperature = 0.3
        settings.openAITopP = 0.8
        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = "x-work-key"
        settings.openAIAPIKey = "sk-work"

        settings.addOpenAIConnection()
        let local = settings.activeOpenAIConnectionID
        settings.openAIEndpoint = "http://localhost:11434/v1"
        settings.openAIModel = "llama3.1"
        settings.openAITemperature = nil
        settings.openAITopP = nil
        settings.openAIAPIKeyPlacement = .bearerToken
        settings.openAIAPIKeyHeaderName = "x-local-key"
        settings.openAIAPIKey = "sk-local"

        settings.selectOpenAIConnection(work)
        XCTAssertEqual(settings.openAIEndpoint, "https://work.example/v1")
        XCTAssertEqual(settings.openAIModel, "gpt-work")
        XCTAssertEqual(settings.openAITemperature, 0.3)
        XCTAssertEqual(settings.openAITopP, 0.8)
        XCTAssertEqual(settings.openAIAPIKeyPlacement, .customHeader)
        XCTAssertEqual(settings.openAIAPIKeyHeaderName, "x-work-key")
        XCTAssertEqual(settings.openAIAPIKey, "sk-work")

        settings.selectOpenAIConnection(local)
        XCTAssertEqual(settings.openAIEndpoint, "http://localhost:11434/v1")
        XCTAssertNil(settings.openAITemperature)
        XCTAssertNil(settings.openAITopP)
        XCTAssertEqual(settings.openAIAPIKeyHeaderName, "x-local-key")
        XCTAssertEqual(settings.openAIAPIKey, "sk-local")
    }

    func testConnectionsAndSelectionSurviveARelaunch() {
        settings = makeSettings()
        settings.openAIEndpoint = "https://work.example/v1"
        settings.addOpenAIConnection()
        settings.renameActiveOpenAIConnection("Local Ollama")
        settings.openAIEndpoint = "http://localhost:11434/v1"
        settings.openAIAPIKey = "sk-local"
        let local = settings.activeOpenAIConnectionID

        settings = makeSettings()

        XCTAssertEqual(settings.openAIConnections.map(\.name), ["Default", "Local Ollama"])
        XCTAssertEqual(settings.activeOpenAIConnectionID, local)
        XCTAssertEqual(settings.openAIEndpoint, "http://localhost:11434/v1")
        XCTAssertEqual(settings.openAIAPIKey, "sk-local")
        settings.selectOpenAIConnection(settings.openAIConnections[0].id)
        XCTAssertEqual(settings.openAIEndpoint, "https://work.example/v1")
    }

    func testALostSelectionLoadsTheFirstConnectionWithItsOwnValues() {
        settings = makeSettings()
        settings.openAIEndpoint = "https://work.example/v1"
        settings.openAIAPIKey = "sk-work"
        settings.addOpenAIConnection()
        settings.openAIEndpoint = "http://localhost:11434/v1"
        defaults.set("not-a-connection", forKey: "activeOpenAIConnectionID")

        settings = makeSettings()

        XCTAssertEqual(settings.activeOpenAIConnectionID, settings.openAIConnections[0].id)
        XCTAssertEqual(settings.openAIEndpoint, "https://work.example/v1")
        XCTAssertEqual(settings.openAIAPIKey, "sk-work")
    }

    func testAnUnreadableConnectionIsDroppedAndTheRestKept() throws {
        settings = makeSettings()
        settings.openAIEndpoint = "https://work.example/v1"
        settings.openAIAPIKey = "sk-work"
        settings.addOpenAIConnection()
        settings.renameActiveOpenAIConnection("Local Ollama")
        settings.openAIEndpoint = "http://localhost:11434/v1"
        settings.openAIAPIKey = "sk-local"
        settings.addOpenAIConnection()
        settings.renameActiveOpenAIConnection("Future")
        settings.openAIEndpoint = "https://future.example/v1"
        settings.selectOpenAIConnection(settings.openAIConnections[1].id)
        // A later release's key placement this one cannot decode.
        let stored = try XCTUnwrap(defaults.data(forKey: "openAIConnections"))
        var list = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [[String: Any]])
        list[2]["apiKeyPlacement"] = "queryParameter"
        let edited = try JSONSerialization.data(withJSONObject: list)
        defaults.set(edited, forKey: "openAIConnections")

        settings = makeSettings()

        XCTAssertEqual(settings.openAIConnections.map(\.name), ["Default", "Local Ollama"])
        XCTAssertEqual(settings.activeOpenAIConnection?.name, "Local Ollama")
        XCTAssertEqual(settings.openAIEndpoint, "http://localhost:11434/v1")
        XCTAssertEqual(settings.openAIAPIKey, "sk-local")
        XCTAssertEqual(defaults.data(forKey: "openAIConnectionsUnreadable"), edited)
    }

    func testAnUnreadableListStartsAFreshConnectionWithoutTheOriginalKey() throws {
        settings = makeSettings()
        settings.openAIAPIKey = "sk-work"
        settings.addOpenAIConnection()
        settings.openAIEndpoint = "http://localhost:11434/v1"
        let unreadable = Data("{\"not\":\"a list\"}".utf8)
        defaults.set(unreadable, forKey: "openAIConnections")

        settings = makeSettings()

        let only = try XCTUnwrap(settings.openAIConnections.first)
        XCTAssertEqual(settings.openAIConnections.count, 1)
        XCTAssertFalse(only.usesOriginalKeychainItem)
        XCTAssertEqual(settings.activeOpenAIConnectionID, only.id)
        XCTAssertEqual(settings.openAIAPIKey, "")
        XCTAssertEqual(KeychainHelper.read(key: apiKeyAccount), "sk-work")
        XCTAssertEqual(defaults.data(forKey: "openAIConnectionsUnreadable"), unreadable)
    }

    func testAStoredValueOfAnotherTypeIsNotTakenForNothingStored() throws {
        KeychainHelper.save(key: apiKeyAccount, value: "sk-work")
        defaults.set("not data", forKey: "openAIConnections")

        settings = makeSettings()

        let only = try XCTUnwrap(settings.openAIConnections.first)
        XCTAssertFalse(only.usesOriginalKeychainItem)
        XCTAssertEqual(settings.openAIAPIKey, "")
    }

    func testDeletingSelectsThePreviousConnectionAndRemovesTheKey() throws {
        settings = makeSettings()
        settings.openAIEndpoint = "https://work.example/v1"
        settings.openAIAPIKey = "sk-work"
        settings.addOpenAIConnection()
        settings.openAIEndpoint = "http://localhost:11434/v1"
        settings.openAIAPIKey = "sk-local"
        let removed = try XCTUnwrap(settings.activeOpenAIConnection)

        settings.deleteActiveOpenAIConnection()

        XCTAssertEqual(settings.openAIConnections.map(\.name), ["Default"])
        XCTAssertEqual(settings.openAIEndpoint, "https://work.example/v1")
        XCTAssertEqual(settings.openAIAPIKey, "sk-work")
        XCTAssertNil(KeychainHelper.read(key: settings.openAIKeyAccount(for: removed)))
    }

    func testDeletingTheFirstConnectionSelectsTheNextOne() {
        settings = makeSettings()
        settings.openAIEndpoint = "https://work.example/v1"
        settings.openAIAPIKey = "sk-work"
        settings.addOpenAIConnection()
        settings.openAIEndpoint = "http://localhost:11434/v1"
        settings.openAIAPIKey = "sk-local"
        settings.selectOpenAIConnection(settings.openAIConnections[0].id)

        settings.deleteActiveOpenAIConnection()

        XCTAssertEqual(settings.openAIConnections.map(\.name), ["Connection 2"])
        XCTAssertEqual(settings.activeOpenAIConnection?.name, "Connection 2")
        XCTAssertEqual(settings.openAIEndpoint, "http://localhost:11434/v1")
        XCTAssertEqual(settings.openAIAPIKey, "sk-local")
    }

    func testANewNameSkipsANameAlreadyTaken() {
        settings = makeSettings()
        settings.renameActiveOpenAIConnection("Connection 2")

        XCTAssertEqual(settings.nextOpenAIConnectionName(), "Connection 3")
    }

    func testTheLastConnectionCannotBeDeleted() {
        settings = makeSettings()
        settings.openAIAPIKey = "sk-work"

        settings.deleteActiveOpenAIConnection()

        XCTAssertEqual(settings.openAIConnections.count, 1)
        XCTAssertEqual(settings.openAIAPIKey, "sk-work")
    }

    func testAnEmptyNameStillShowsALabel() {
        settings = makeSettings()
        settings.renameActiveOpenAIConnection("  ")
        XCTAssertEqual(settings.activeOpenAIConnection?.displayName, "Untitled Connection")
    }
}
