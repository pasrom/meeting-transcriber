import Foundation

enum ContextMCPKeychain {
    static func load(_ source: MCPSource) -> MCPSecrets {
        guard let value = KeychainHelper.read(key: source.credentialAccount) else { return MCPSecrets() }
        return (try? JSONDecoder().decode(MCPSecrets.self, from: Data(value.utf8))) ?? MCPSecrets()
    }

    static func save(_ value: MCPSecrets, for source: MCPSource) -> Bool {
        guard let encoded = try? ContextJSON.encodedText(value) else { return false }
        KeychainHelper.save(key: source.credentialAccount, value: encoded)
        return KeychainHelper.read(key: source.credentialAccount) == encoded
    }

    static func remove(_ source: MCPSource) {
        KeychainHelper.delete(key: source.credentialAccount)
    }
}
