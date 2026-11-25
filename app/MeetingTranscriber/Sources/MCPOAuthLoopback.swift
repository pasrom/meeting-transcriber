import AppKit
import Foundation
import Network

/// One browser OAuth callback on an IPv4 loopback-only listener.
@MainActor
final class MCPOAuthLoopback {
    private let listener: NWListener
    private var ready: CheckedContinuation<URL, any Error>?
    private var pending: CheckedContinuation<String, any Error>?
    private var flow: MCPOAuthClient.Flow?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]

    init(port: UInt16 = MCPOAuthClient.loopbackPort) throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.update(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                accept(connection)
            }
        }
    }

    func start() async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                timer(seconds: 8)
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func authorize(
        _ flow: MCPOAuthClient.Flow, seconds: Int = 300, open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
    ) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.flow = flow
                pending = continuation
                timer(seconds: seconds)
                if !open(flow.authorizationURL) { finish(.failure(MCPOAuthError.callback)) }
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func stop() {
        if let ready {
            self.ready = nil
            ready.resume(throwing: CancellationError())
        }
        finish(.failure(CancellationError()))
    }

    private func update(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let ready else { return }
            self.ready = nil
            timeout?.cancel()
            if let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") {
                ready.resume(returning: url)
            } else {
                ready.resume(throwing: MCPOAuthError.callback)
            }

        case .failed:
            if let ready {
                self.ready = nil
                ready.resume(throwing: MCPOAuthError.callback)
            }
            finish(.failure(MCPOAuthError.callback))

        default:
            break
        }
    }

    private func timer(seconds: Int) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self else { return }
            if let ready {
                self.ready = nil
                ready.resume(throwing: MCPOAuthError.callback)
            }
            finish(.failure(MCPOAuthError.callback))
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        timeout?.cancel()
        timeout = nil
        listener.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        let continuation = pending
        pending = nil
        flow = nil
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        guard flow != nil, connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        read(id, bytes: Data())
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func read(_ id: UUID, bytes: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, closed, error in
            Task { @MainActor in
                guard let self, connections[id] != nil else { return }
                var received = bytes
                if let data { received.append(data) }
                if received.count > 16 * 1024 || error != nil {
                    reject(id)
                } else if let end = received.range(of: Data("\r\n\r\n".utf8))?.lowerBound {
                    handle(id, header: Data(received[..<end]))
                } else if closed {
                    reject(id)
                } else {
                    read(id, bytes: received)
                }
            }
        }
    }

    private func handle(_ id: UUID, header: Data) {
        guard let flow, let request = String(data: header, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
            reject(id)
            return
        }
        let fields = request.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET", fields[2].hasPrefix("HTTP/1."),
              fields[1].hasPrefix(flow.redirect.path + "?"),
              let port = flow.redirect.port, let url = URL(string: "http://127.0.0.1:\(port)" + fields[1]) else {
            reject(id)
            return
        }
        do {
            let code = try flow.code(from: url)
            respond(id, status: "200 OK", text: "Return to Meeting Transcriber to finish signing in.")
            finish(.success(code))
        } catch MCPOAuthError.denied {
            respond(id, status: "200 OK", text: "Sign-in was declined. Return to Meeting Transcriber.")
            finish(.failure(MCPOAuthError.denied))
        } catch {
            // An unrelated localhost request must not terminate a valid sign-in.
            reject(id)
        }
    }

    private func reject(_ id: UUID) {
        respond(id, status: "400 Bad Request", text: "Invalid callback.")
    }

    private func respond(_ id: UUID, status: String, text: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(text.utf8.count)\r\n\r\n"
        connection.send(content: Data((header + text).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
