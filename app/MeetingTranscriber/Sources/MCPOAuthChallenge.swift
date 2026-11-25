import Foundation

/// Extracts Bearer parameters while respecting quoted values and other schemes
/// combined into the same WWW-Authenticate header.
struct MCPOAuthChallenge {
    let metadata: String?
    let scope: String?

    init(_ header: String?) throws {
        guard (header?.utf8.count ?? 0) <= 8192 else { throw MCPOAuthError.discovery }
        var bearer = false
        var values: [String: String] = [:]
        for part in Self.parts(header ?? "") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split(maxSplits: 1) { $0.isWhitespace }
            var parameter = trimmed
            let remainder = words.count == 2 ? words[1].trimmingCharacters(in: .whitespaces) : ""
            if let first = words.first, !first.contains("="), !remainder.hasPrefix("=") {
                bearer = first.lowercased() == "bearer"
                parameter = remainder
            }
            guard bearer, let separator = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "resource_metadata" || key == "scope" else { continue }
            guard values[key] == nil else { throw MCPOAuthError.discovery }
            var value = parameter[parameter.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            guard !value.contains("\""), !value.contains("\\"), !value.isEmpty else { throw MCPOAuthError.discovery }
            values[key] = value
        }
        metadata = values["resource_metadata"]
        scope = values["scope"]
    }

    private static func parts(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in header {
            if character == ",", !quoted {
                parts.append(current)
                current = ""
                continue
            }
            if character == "\"", !escaped { quoted.toggle() }
            escaped = character == "\\" && quoted && !escaped
            current.append(character)
        }
        return parts + [current]
    }
}
