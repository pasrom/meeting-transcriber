import Foundation

/// A saved OpenAI-compatible meeting-notes connection (Settings → Output → AI Provider).
///
/// Holds everything but the API key, which stays in the Keychain under
/// `AppSettings.openAIKeyAccount(for:)`. The selected connection's values are
/// the live `openAI*` settings; this copy is refreshed from them when another
/// connection is selected or added.
struct OpenAIConnection: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var endpoint: String
    var model: String
    var temperature: Double?
    var topP: Double?
    var apiKeyPlacement: OpenAIAPIKeyPlacement
    var apiKeyHeaderName: String
    /// True only for the connection made from the settings that existed
    /// before connections did: it keeps the Keychain item the key was already in.
    var usesOriginalKeychainItem = false

    /// Name shown in the picker, so a cleared name field still leaves a label.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Connection" : trimmed
    }

    /// Decode a stored list one connection at a time, so one this build cannot
    /// read (an unknown enum value or a missing required field) drops only itself.
    /// `complete` is false when anything, or the whole list, was unreadable.
    static func decodeList(_ data: Data) -> (connections: [Self], complete: Bool) {
        guard let elements = try? JSONDecoder().decode([Lossy].self, from: data) else { return ([], false) }
        let connections = elements.compactMap(\.connection)
        return (connections, connections.count == elements.count)
    }

    private struct Lossy: Decodable {
        let connection: OpenAIConnection?

        init(from decoder: any Decoder) {
            connection = try? OpenAIConnection(from: decoder)
        }
    }
}
