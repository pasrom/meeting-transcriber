@testable import MeetingTranscriber
import XCTest

@MainActor
final class CloudEndpointDraftsTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var suiteName: String!
    private var keyAccount: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "CloudEndpointDraftsTests-\(getpid())-\(UUID().uuidString)"
        keyAccount = "CloudEndpointDraftsTests-key-\(getpid())-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        KeychainHelper.delete(key: keyAccount)
        KeychainHelper.delete(key: keyAccount + ".alternate")
        DefaultsSuite.remove(suiteName)
        try await super.tearDown()
    }

    func testAFailedKeyWriteStoresNeitherTheEndpointNorTheKey() throws {
        // Even if an earlier save left the desired value in the spare slot,
        // a failing write must not commit the new endpoint.
        try assertSaveFails(draftKey: "sk-new") { value, account in
            XCTAssertTrue(KeychainHelper.save(key: account, value: value))
            return false
        }
    }

    func testAFailedKeyDeleteStoresNeitherTheEndpointNorTheKey() throws {
        try assertSaveFails(draftKey: "") { value, _ in
            XCTAssertTrue(value.isEmpty)
            return false
        }
    }

    func testUnverifiedWriteKeepsPreviouslyActiveKeyAndEndpoint() throws {
        try assertSaveFails(draftKey: "sk-new") { _, account in
            KeychainHelper.save(key: account, value: "unverified")
        }
    }

    private func assertSaveFails(draftKey: String, store: @escaping @MainActor (String, String) -> Bool) throws {
        let defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
        XCTAssertTrue(KeychainHelper.save(key: keyAccount, value: "sk-old"))
        let settings = AppSettings(defaults: defaults, cloudTranscriptionAPIKeyAccount: keyAccount)
        settings.cloudTranscriptionBaseURL = "https://old.example.com/v1"
        let drafts = CloudEndpointDrafts(storeKey: store)
        drafts.load(from: settings)
        drafts.baseURL = "https://new.example.com/v1"
        drafts.apiKey = draftKey

        drafts.save(to: settings)

        let restored = AppSettings(defaults: defaults, cloudTranscriptionAPIKeyAccount: keyAccount)
        XCTAssertEqual(restored.cloudTranscriptionBaseURL, "https://old.example.com/v1")
        XCTAssertEqual(restored.cloudTranscriptionAPIKey, "sk-old")
        XCTAssertTrue(drafts.hasChanges)
    }
}
