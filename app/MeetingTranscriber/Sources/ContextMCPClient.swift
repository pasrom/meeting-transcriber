import Foundation

struct MCPWireReply: Sendable {
    let result: ContextJSON
    var session: String?
}

struct MCPWireMessage: Sendable {
    let id: Int?
    let method: String
    let data: Data

    init(_ method: String, id: Int?, params: [String: ContextJSON] = [:]) throws {
        self.id = id
        self.method = method
        var fields: [String: ContextJSON] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { fields["id"] = .integer(id) }
        if !params.isEmpty { fields["params"] = .object(params) }
        data = try ContextJSON.encoded(fields)
    }

    static func decode(_ data: Data) throws -> ContextJSON {
        let value = try JSONDecoder().decode(ContextJSON.self, from: data)
        guard value["jsonrpc"] == .string("2.0"), value.object != nil else { throw ContextFailure.invalidResponse }
        return value
    }

    static func response(_ value: ContextJSON, id: Int) throws -> ContextJSON? {
        guard value["id"] == .integer(id), value["method"] == nil else { return nil }
        guard let result = value["result"], value["error"] == nil, result.object != nil else {
            if value["error"]?.object != nil { throw ContextFailure.toolError }
            throw ContextFailure.invalidResponse
        }
        return result
    }

    static func listChanged(_ value: ContextJSON) -> Bool {
        value["method"] == .string("notifications/tools/list_changed") && value["id"] == nil
    }
}

protocol MCPContextTransport: Actor {
    func exchange(_ message: MCPWireMessage, seconds: TimeInterval) async throws -> MCPWireReply
    func setProtocolVersion(_ version: String) async
    func takeToolListChange() async -> Bool
    func close(endSession: Bool) async
}

/// One MCP session per source and job. The application performs the handshake
/// and sends only tools/list and vetted tools/call after initialization.
actor ContextMCPClient {
    private static let supportedVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private let source: MCPSource
    private let transport: any MCPContextTransport
    private let stillAuthorized: @MainActor @Sendable () -> Bool
    private let deadline: ContinuousClock.Instant
    private var nextID = 0
    private var catalog: [MCPTool] = []

    init(
        source: MCPSource, secrets: MCPSecrets, deadline: ContinuousClock.Instant,
        stillAuthorized: @escaping @MainActor @Sendable () -> Bool,
    ) throws {
        self.source = source
        self.deadline = deadline
        self.stillAuthorized = stillAuthorized
        switch source.transport {
        case .http:
            guard let url = source.endpoint else { throw ContextFailure.invalidEndpoint }
            transport = try MCPHTTPTransport(endpoint: url, headers: secrets.headers)

        case .stdio:
            #if APPSTORE
                throw ContextFailure.unavailable
            #else
                transport = MCPStdioTransport(source: source, environment: secrets.environment)
            #endif
        }
    }

    func discover() async throws -> [MCPTool] {
        let hello = try await request("initialize", params: [
            "protocolVersion": .string("2025-11-25"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Meeting Transcriber"), "version": .string("1")]),
        ])
        guard let version = hello["protocolVersion"]?.string, Self.supportedVersions.contains(version),
              source.transport != .http || version != "2024-11-05" else { throw ContextFailure.unsupportedVersion }
        guard hello["capabilities"]?.object != nil, hello["serverInfo"]?["name"]?.string != nil,
              hello["serverInfo"]?["version"]?.string != nil else { throw ContextFailure.invalidResponse }
        await transport.setProtocolVersion(version)
        try await checkAuthorization()
        _ = try await exchange(MCPWireMessage("notifications/initialized", id: nil))
        guard hello["capabilities"]?["tools"]?.object != nil else { return [] }
        return try await refresh()
    }

    func call(_ tool: MCPTool, arguments: ContextJSON) async throws -> ContextJSON {
        if await transport.takeToolListChange() { _ = try await refresh() }
        guard catalog.contains(where: { $0.name == tool.name && $0.fingerprint == tool.fingerprint }) else {
            throw ContextFailure.revoked
        }
        return try await request("tools/call", params: ["name": .string(tool.name), "arguments": arguments])
    }

    func close() async {
        let endSession = !Task.isCancelled && deadline > ContinuousClock.now
        await transport.close(endSession: endSession ? stillAuthorized() : false)
    }

    private func refresh() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var seenNames: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        var announced = 0
        for _ in 0 ..< ContextLimits.pages {
            let result = try await request("tools/list", params: cursor.map { ["cursor": .string($0)] } ?? [:])
            guard let listed = result["tools"]?.array else { throw ContextFailure.invalidResponse }
            announced += listed.count
            guard announced <= ContextLimits.tools else { throw ContextFailure.limit }
            for value in listed {
                guard let name = value["name"]?.string, seenNames.insert(name).inserted else {
                    throw ContextFailure.invalidResponse
                }
                if let tool = MCPTool(wire: value) { tools.append(tool) }
            }
            if result["nextCursor"] == nil || result["nextCursor"] == .null {
                catalog = tools
                return tools
            }
            guard let next = result["nextCursor"]?.string, !next.isEmpty, next.utf8.count <= 1024,
                  cursors.insert(next).inserted else { throw ContextFailure.invalidResponse }
            cursor = next
        }
        throw ContextFailure.limit
    }

    private func checkAuthorization() async throws {
        try Task.checkCancellation()
        guard await stillAuthorized() else { throw ContextFailure.revoked }
        try Task.checkCancellation()
    }

    private func remaining() throws -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard seconds > 0 else { throw ContextFailure.timeout }
        return min(seconds, Double(ContextLimits.operationSeconds))
    }

    private func request(_ method: String, params: [String: ContextJSON] = [:]) async throws -> ContextJSON {
        try await checkAuthorization()
        nextID += 1
        let message = try MCPWireMessage(method, id: nextID, params: params)
        return try await exchange(message).result
    }

    private func exchange(_ message: MCPWireMessage) async throws -> MCPWireReply {
        let seconds = try remaining()
        let authorized = stillAuthorized
        let transport = transport
        return try await withThrowingTaskGroup(of: MCPWireReply.self) { group in
            group.addTask {
                guard await authorized() else { throw ContextFailure.revoked }
                try Task.checkCancellation()
                return try await transport.exchange(message, seconds: seconds)
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(150))
                    guard await authorized() else { throw ContextFailure.revoked }
                }
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw ContextFailure.connection }
            return reply
        }
    }
}
