import Foundation

/// Refresh token rotation is serialized per saved credential revision. OAuth
/// never launches a browser during notes processing.
actor MCPOAuthTokenStore {
    static let shared = MCPOAuthTokenStore()

    private var refreshing: [String: Task<MCPSecrets, any Error>] = [:]

    func usable(
        _ source: MCPSource, deadline: ContinuousClock.Instant, authorized: @escaping ContextEnrichment.Authorization,
    ) async throws -> MCPSecrets {
        try Task.checkCancellation()
        guard await authorized(source), source.usesOAuth, let endpoint = source.endpoint else { throw ContextFailure.revoked }
        let saved = ContextMCPKeychain.load(source)
        guard let token = saved.oauth, token.matches(endpoint) else { throw MCPOAuthError.expired }
        guard token.needsRefresh(at: Date()), token.refreshToken != nil else {
            guard token.expiresAt.map({ $0 > Date() }) ?? true else { throw MCPOAuthError.expired }
            return saved
        }
        let account = source.credentialAccount
        if let pending = refreshing[account] { return try await pending.value }
        let pending = Task {
            guard await authorized(source) else { throw ContextFailure.revoked }
            let duration = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            guard seconds > 0 else { throw ContextFailure.timeout }
            let refreshed = try await MCPOAuthClient().refresh(token, timeout: seconds)
            let value = MCPSecrets(oauth: refreshed)
            try await MainActor.run {
                guard authorized(source) else { throw ContextFailure.revoked }
                guard ContextMCPKeychain.save(value, for: source) else { throw MCPOAuthError.storage }
            }
            return value
        }
        refreshing[account] = pending
        defer { refreshing.removeValue(forKey: account) }
        return try await pending.value
    }
}
