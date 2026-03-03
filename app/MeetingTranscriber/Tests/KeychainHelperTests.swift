import Foundation
import XCTest

@testable import MeetingTranscriber

final class KeychainHelperTests: XCTestCase {

    private let testKey = "KEYCHAIN_TEST_\(UUID().uuidString)"

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
