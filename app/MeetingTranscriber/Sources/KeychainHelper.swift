import Foundation
import os.log
import Security

/// Legacy macOS Keychain wrapper, kept for a single read-only purpose:
/// migrating the OpenAI API key out of the Keychain into file-based
/// storage on first launch after upgrade (`AppSettings.loadOpenAIKey`).
///
/// Don't add new callers. New secrets follow the file pattern at
/// `AppPaths.dataDir/.<secret-name>` with `chmod 0600` (see
/// `DebugRPCServer.tokenFileURL` for the canonical example). Keychain
/// requires UI prompts under non-interactive launchd contexts (e.g.
/// self-hosted CI on macOS), which makes it a footgun for anything we
/// also want to exercise from xctest.
enum KeychainHelper {
    private static let service = AppPaths.logSubsystem
    private static let logger = Logger(subsystem: AppPaths.logSubsystem, category: "KeychainHelper")

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Store or update a value in the Keychain.
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary)
            if updateStatus != errSecSuccess {
                logger.error("Failed to update \(key): \(updateStatus)")
            }
        } else if addStatus != errSecSuccess {
            logger.error("Failed to save \(key): \(addStatus)")
        }
    }

    /// Read a value from the Keychain. Returns `nil` if not found.
    static func read(key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from the Keychain.
    static func delete(key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    /// Check whether a value exists in the Keychain.
    static func exists(key: String) -> Bool {
        var query = baseQuery(for: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
