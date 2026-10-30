import Foundation
@testable import MeetingTranscriber
import XCTest

final class KeychainHelperTests: XCTestCase {
    private let testKey = "KEYCHAIN_TEST_\(UUID().uuidString)"

    /// Removes the item an earlier round-trip test left under a fixed name in the
    /// account's keychain, which both CI runners share. Remove once no runner
    /// can still hold one.
    override static func setUp() {
        super.setUp()
        KeychainHelper.delete(key: "HF_TOKEN_TEST")
    }

    override func tearDown() {
        KeychainHelper.delete(key: testKey)
        super.tearDown()
    }

    // MARK: - Save: add path (item doesn't exist)

    func testSaveAddsNewItem() {
        KeychainHelper.save(key: testKey, value: "secret123")
        XCTAssertEqual(KeychainHelper.read(key: testKey), "secret123")
    }

    // MARK: - Save: update path (item already exists)

    func testSaveUpdatesExistingItem() {
        KeychainHelper.save(key: testKey, value: "original")
        KeychainHelper.save(key: testKey, value: "updated")
        XCTAssertEqual(KeychainHelper.read(key: testKey), "updated")
    }

    // MARK: - Read non-existent key

    func testReadNonExistentReturnsNil() {
        XCTAssertNil(KeychainHelper.read(key: "KEYCHAIN_NONEXISTENT_\(UUID().uuidString)"))
    }

    // MARK: - Exists

    func testExistsReturnsFalseForMissingKey() {
        XCTAssertFalse(KeychainHelper.exists(key: "KEYCHAIN_NONEXISTENT_\(UUID().uuidString)"))
    }

    func testExistsReturnsTrueAfterSave() {
        KeychainHelper.save(key: testKey, value: "value")
        XCTAssertTrue(KeychainHelper.exists(key: testKey))
    }

    // MARK: - Delete idempotency

    func testDeleteNonExistentKeyDoesNotCrash() {
        // Should be a no-op, not crash
        KeychainHelper.delete(key: "KEYCHAIN_NONEXISTENT_\(UUID().uuidString)")
    }

    func testDoubleDeleteDoesNotCrash() {
        KeychainHelper.save(key: testKey, value: "toDelete")
        KeychainHelper.delete(key: testKey)
        KeychainHelper.delete(key: testKey)
        XCTAssertFalse(KeychainHelper.exists(key: testKey))
    }

    // MARK: - Delete clears read and exists

    func testDeleteClearsValue() {
        KeychainHelper.save(key: testKey, value: "temporary")
        XCTAssertTrue(KeychainHelper.exists(key: testKey))

        KeychainHelper.delete(key: testKey)
        XCTAssertNil(KeychainHelper.read(key: testKey))
        XCTAssertFalse(KeychainHelper.exists(key: testKey))
    }
}
