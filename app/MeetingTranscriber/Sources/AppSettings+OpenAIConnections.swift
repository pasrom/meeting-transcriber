import Foundation

/// Saved OpenAI-compatible connections: add, select, rename, delete.
///
/// The live `openAI*` settings stay what the pipeline, the RPC API and Test
/// Connection read; selecting a connection copies its values into them, and
/// the key follows because `openAIAPIKey` reads the selected connection's
/// Keychain item.
extension AppSettings {
    var activeOpenAIConnection: OpenAIConnection? {
        openAIConnections.first { $0.id == activeOpenAIConnectionID }
    }

    /// Add a connection with the current settings but no API key, and select it.
    func addOpenAIConnection(named name: String? = nil) {
        storeLiveValuesInActiveConnection()
        var connection = liveConnectionValues(id: UUID())
        connection.name = name ?? nextOpenAIConnectionName()
        openAIConnections.append(connection)
        activeOpenAIConnectionID = connection.id
    }

    func selectOpenAIConnection(_ id: UUID) {
        guard id != activeOpenAIConnectionID,
              let target = openAIConnections.first(where: { $0.id == id }) else { return }
        storeLiveValuesInActiveConnection()
        applyOpenAIConnection(target)
    }

    /// Make `target` the selected connection and its values the live settings.
    func applyOpenAIConnection(_ target: OpenAIConnection) {
        activeOpenAIConnectionID = target.id
        openAIEndpoint = target.endpoint
        openAIModel = target.model
        openAITemperature = target.temperature
        openAITopP = target.topP
        openAIAPIKeyPlacement = target.apiKeyPlacement
        openAIAPIKeyHeaderName = target.apiKeyHeaderName
    }

    func renameActiveOpenAIConnection(_ name: String) {
        guard let index = openAIConnections.firstIndex(where: { $0.id == activeOpenAIConnectionID }) else { return }
        openAIConnections[index].name = name
    }

    /// Delete the selected connection and its API key, then select the one
    /// before it. The last connection cannot be deleted.
    func deleteActiveOpenAIConnection() {
        guard openAIConnections.count > 1,
              let index = openAIConnections.firstIndex(where: { $0.id == activeOpenAIConnectionID }) else { return }
        let removed = openAIConnections[index]
        selectOpenAIConnection(openAIConnections[index == 0 ? 1 : index - 1].id)
        openAIConnections.removeAll { $0.id == removed.id }
        KeychainHelper.delete(key: openAIKeyAccount(for: removed))
    }

    private func storeLiveValuesInActiveConnection() {
        guard let index = openAIConnections.firstIndex(where: { $0.id == activeOpenAIConnectionID }) else { return }
        let stored = openAIConnections[index]
        var updated = liveConnectionValues(id: stored.id)
        updated.name = stored.name
        updated.usesOriginalKeychainItem = stored.usesOriginalKeychainItem
        if updated != stored { openAIConnections[index] = updated }
    }

    private func liveConnectionValues(id: UUID) -> OpenAIConnection {
        OpenAIConnection(
            id: id, name: "", endpoint: openAIEndpoint, model: openAIModel,
            temperature: openAITemperature, topP: openAITopP,
            apiKeyPlacement: openAIAPIKeyPlacement, apiKeyHeaderName: openAIAPIKeyHeaderName,
        )
    }

    /// "Connection N", numbered past the names already taken.
    func nextOpenAIConnectionName() -> String {
        let names = Set(openAIConnections.map(\.displayName))
        var number = openAIConnections.count + 1
        while names.contains("Connection \(number)") {
            number += 1
        }
        return "Connection \(number)"
    }
}
