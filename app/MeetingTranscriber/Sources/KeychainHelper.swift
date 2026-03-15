import Foundation

// MARK: - Test-only utility (no production references)

/// File-based secret storage in the app's data directory.
/// Stored with POSIX 600 permissions (owner read/write only).
/// Same API as the previous Keychain-based implementation but survives
/// app re-signing and bundle recreation.
enum KeychainHelper {
    private static let secretsDir = AppPaths.dataDir.appendingPathComponent(".secrets")

    private static func path(for key: String) -> URL {
        secretsDir.appendingPathComponent(key)
    }

    /// Store or update a value.
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
            // Set directory permissions to 700
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: secretsDir.path,
            )
            let url = path(for: key)
            try data.write(to: url, options: .atomic)
            // Set file permissions to 600
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path,
            )
        } catch {
            NSLog("KeychainHelper: failed to save \(key): \(error)")
        }
    }

    /// Read a value. Returns `nil` if not found.
    static func read(key: String) -> String? {
        guard let data = try? Data(contentsOf: path(for: key)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value.
    static func delete(key: String) {
        try? FileManager.default.removeItem(at: path(for: key))
    }

    /// Check whether a value exists.
    static func exists(key: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: key).path)
    }
}
