import Foundation

enum ContextLimits {
    static let servers = 8
    static let pages = 4
    static let tools = 48
    static let calls = 12
    static let operationSeconds = 15
    static let stageSeconds = 90
    static let arguments = 4096
    static let queryTextPerCall = 384
    static let queryTextPerMeeting = 1024
    static let result = 32 * 1024
    static let wire = 128 * 1024
    static let context = 16 * 1024
    static let plannerReply = 16 * 1024
    static let plannerOutputTokens = 4096
    static let notesReply = 256 * 1024
    static let responseEnvelope = 32 * 1024
    static let plannerInput = 20 * 1024
    static let notesInput = 48 * 1024
}

// These names are the version-one provenance codes.
enum ContextFailure: String, Error, Codable {
    // swiftlint:disable raw_value_for_camel_cased_codable_enum
    case invalidEndpoint, connection, authentication, invalidResponse, unsupportedVersion
    case limit, timeout, revoked, unavailable, toolError, unsupportedContent, unsafeData
    // swiftlint:enable raw_value_for_camel_cased_codable_enum
}

enum ContextJSON: Codable, Equatable, Sendable {
    case object([String: Self]), array([Self]), string(String), integer(Int), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 24 else { throw ContextFailure.limit }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? value.decode(Int.self) {
            self = .integer(integer)
        } else if let double = try? value.decode(Double.self) {
            self = .number(double)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([Self].self) {
            self = .array(array)
        } else {
            self = try .object(value.decode([String: Self].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    // Distinguish invalid JSON types from valid empty objects and arrays.
    // swiftlint:disable:next discouraged_optional_collection
    var object: [String: Self]? {
        if case let .object(value) = self { value } else { nil }
    }

    // swiftlint:disable:next discouraged_optional_collection
    var array: [Self]? {
        if case let .array(value) = self { value } else { nil }
    }

    var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    subscript(_ key: String) -> Self? {
        object?[key]
    }

    static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func encodedText(_ value: some Encodable) throws -> String {
        guard let text = try String(data: encoded(value), encoding: .utf8) else { throw ContextFailure.invalidResponse }
        return text
    }
}

struct MCPSource: Codable, Equatable, Identifiable, Sendable {
    enum Transport: String, Codable, CaseIterable, Sendable {
        case stdio
        case http
        var label: String {
            self == .stdio ? "Local stdio" : "Streamable HTTP"
        }
    }

    var id = UUID()
    var name = "Knowledge source"
    var transport: Transport = .http
    var enabled = false
    var location = ""
    var arguments: [String] = []
    var allowQueries = false
    var allowLocalHTTP = false
    var remoteModelDestination: String?
    var retainEvidence = false
    var approvals: [String: String] = [:]
    // Rotating credentials invalidates approvals and any in-flight authorization.
    var connectionRevision = UUID()

    var credentialAccount: String {
        "mcp-source-\(id.uuidString)-\(connectionRevision.uuidString)"
    }

    var endpoint: URL? {
        guard transport == .http, let url = URL(string: location), Self.validEndpoint(url, allowLoopbackHTTP: allowLocalHTTP),
              url.query == nil else { return nil }
        return url
    }

    static func validEndpoint(_ url: URL, allowLoopbackHTTP: Bool) -> Bool {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else {
            return false
        }
        return url.scheme?.lowercased() == "https"
            || (allowLoopbackHTTP && url.scheme?.lowercased() == "http" && isLoopback(url))
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    var transportAvailable: Bool {
        #if APPSTORE
            transport == .http
        #else
            true
        #endif
    }

    static func destinationID(_ url: URL) -> String {
        ContextDigest.hash(Data(url.absoluteString.utf8))
    }

    func canUse(notesEndpoint: URL) -> Bool {
        enabled && transportAvailable && (transport == .stdio || (allowQueries && endpoint != nil))
            && (Self.isLoopback(notesEndpoint) || remoteModelDestination == Self.destinationID(notesEndpoint))
            && !approvals.isEmpty
    }
}

struct MCPSecrets: Codable, Sendable {
    var headers: [String: String] = [:]
    var environment: [String: String] = [:]
    var values: [String] {
        Array(headers.values) + Array(environment.values)
            + headers.values.compactMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
    }
}

struct MCPTool: Sendable {
    let name: String
    let description: String
    let schema: ContextJSON
    let annotations: ContextJSON?
    let fingerprint: String

    init?(wire: ContextJSON) {
        guard let name = wire["name"]?.string, !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let schema = wire["inputSchema"], schema.object != nil,
              let signature = try? ContextJSON.encoded(wire), signature.count <= 12 * 1024 else { return nil }
        self.name = name
        description = wire["description"]?.string ?? ""
        self.schema = schema
        annotations = wire["annotations"]
        // A tool that changes description, schema or annotations must be reviewed again.
        fingerprint = ContextDigest.hash(signature)
    }

    var permitsReadOnlyApproval: Bool {
        let readOnly = annotations?["readOnlyHint"]
        let destructive = annotations?["destructiveHint"]
        return (readOnly == nil || readOnly == .bool(true)) && (destructive == nil || destructive == .bool(false))
            && ContextSchema.catalogSchema(schema) != nil
    }

    var annotationSummary: String? {
        let hints = ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"].compactMap { key -> String? in
            guard case let .bool(value) = annotations?[key] else { return nil }
            return "\(key) = \(value)"
        }
        return hints.isEmpty ? nil : hints.joined(separator: ", ")
    }
}
