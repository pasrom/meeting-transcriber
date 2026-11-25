import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

actor MCPHTTPTransport: MCPContextTransport {
    let endpoint: URL
    let headers: [String: String]
    private var sessionID: String?
    private var version: String?
    private var changed = false

    init(endpoint: URL, headers: [String: String]) throws {
        let reserved = Set([
            "host",
            "accept",
            "content-type",
            "content-length",
            "connection",
            "transfer-encoding",
            "mcp-session-id",
            "mcp-protocol-version",
            "cookie",
            "origin",
            "proxy-authorization",
        ])
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        guard headers.count <= 16, Set(headers.keys.map { $0.lowercased() }).count == headers.count,
              headers.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.count <= 128 && key.unicodeScalars.allSatisfy(allowed.contains)
                      && !reserved.contains(key.lowercased()) && value.utf8.count <= 4096
                      && value.utf8.allSatisfy { (32 ... 126).contains($0) }
              }) else { throw ContextFailure.invalidEndpoint }
        self.endpoint = endpoint
        self.headers = headers
    }

    func exchange(_ message: MCPWireMessage, seconds: TimeInterval) async throws -> MCPWireReply {
        guard message.method != "tools/call" || !changed else { throw ContextFailure.revoked }
        var request = request(method: "POST", seconds: seconds)
        request.httpBody = message.data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let transfer = MCPHTTPTransfer(id: message.id, seconds: seconds)
        let outcome = try await transfer.run(request)
        if message.method == "initialize" { sessionID = outcome.reply.session }
        changed = changed || outcome.changed
        return outcome.reply
    }

    private func request(method: String, seconds: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        return request
    }

    func setProtocolVersion(_ version: String) {
        self.version = version
    }

    func takeToolListChange() -> Bool {
        defer { changed = false }
        return changed
    }

    // No unsolicited HTTP GET stream is opened. Terminate a negotiated
    // session when permitted; servers may return 405 and expire it themselves.
    func close(endSession: Bool) async {
        defer { sessionID = nil }
        guard endSession, sessionID != nil else { return }
        let seconds: TimeInterval = 1
        let request = request(method: "DELETE", seconds: seconds)
        _ = try? await MCPHTTPTransfer(id: nil, seconds: seconds, endingSession: true).run(request)
    }
}

/// Serial URLSession delegate callbacks frame JSON and SSE while reading.
/// A per-transfer session supplies the resource timeout and has no cookies or
/// credential store. Redirects are rejected before URLSession can replay headers.
private final class MCPHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        let reply: MCPWireReply
        let changed: Bool
    }

    private let id: Int?
    private let seconds: TimeInterval
    private let endingSession: Bool
    private let lock = NSLock()
    // Only these two fields are shared with the caller and cancellation handler.
    private var continuation: CheckedContinuation<Outcome, any Error>?
    private var session: URLSession?
    private var cancelled = false
    // The remaining state belongs to the serial URLSession delegate queue.
    private var responseSession: String?
    private var streaming = false
    private var bytes = Data()
    private var event = Data()
    private var received = 0
    private var changed = false

    init(id: Int?, seconds: TimeInterval, endingSession: Bool = false) {
        self.id = id
        self.seconds = seconds
        self.endingSession = endingSession
    }

    func run(_ request: URLRequest) async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = seconds
                    configuration.timeoutIntervalForResource = seconds
                    configuration.httpShouldSetCookies = false
                    configuration.urlCredentialStorage = nil
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    self.continuation = continuation
                    session.dataTask(with: request).resume()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), cancel: true)
        }
    }

    private func finish(_ result: Result<Outcome, any Error>, cancel: Bool = false) {
        let work = lock.withLock {
            cancelled = cancelled || cancel
            let value = (continuation, session)
            continuation = nil
            session = nil
            return value
        }
        work.1?.invalidateAndCancel()
        work.0?.resume(with: result)
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest, completionHandler: @Sendable (URLRequest?) -> Void,
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @Sendable (URLSession.ResponseDisposition) -> Void,
    ) {
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            completionHandler(.cancel)
            finish(.failure(status == 401 || status == 403 ? ContextFailure.authentication : ContextFailure.connection))
            return
        }
        if let value = http.value(forHTTPHeaderField: "MCP-Session-Id") {
            guard !value.isEmpty, value.utf8.count <= 256, value.utf8.allSatisfy({ (33 ... 126).contains($0) }) else {
                completionHandler(.cancel)
                finish(.failure(ContextFailure.invalidResponse))
                return
            }
            responseSession = value
        }
        if endingSession || (id == nil && http.statusCode == 202) {
            completionHandler(.cancel)
            finish(.success(outcome(.object([:]))))
            return
        }
        streaming = http.mimeType?.lowercased() == "text/event-stream"
        guard id != nil, streaming || http.mimeType?.lowercased() == "application/json",
              response.expectedContentLength <= Int64(ContextLimits.wire) else {
            completionHandler(.cancel)
            finish(.failure(ContextFailure.invalidResponse))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        guard received <= ContextLimits.wire else { finish(.failure(ContextFailure.limit)); return }
        bytes.append(data)
        guard streaming else { return }
        do {
            while let newline = bytes.firstIndex(of: 10) {
                let line = bytes[..<newline].last == 13 ? bytes[..<newline].dropLast() : bytes[..<newline]
                let result = try readEventLine(line)
                bytes.removeSubrange(...newline)
                if let result { finish(.success(outcome(result))); return }
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func readEventLine(_ line: Data) throws -> ContextJSON? {
        if line.isEmpty, !event.isEmpty {
            defer { event.removeAll(keepingCapacity: true) }
            return try interpret(event)
        }
        if line.starts(with: "data:".utf8) {
            var value = line.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            if !event.isEmpty { event.append(10) }
            event.append(value)
        }
        return nil
    }

    private func interpret(_ data: Data) throws -> ContextJSON? {
        let message = try MCPWireMessage.decode(data)
        if MCPWireMessage.listChanged(message) { changed = true }
        guard let id else { return nil }
        return try MCPWireMessage.response(message, id: id)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let failure: ContextFailure = (error as? URLError)?.code == .timedOut ? .timeout : .connection
            finish(.failure(failure))
            return
        }
        do {
            guard !streaming, let result = try interpret(bytes) else { throw ContextFailure.invalidResponse }
            finish(.success(outcome(result)))
        } catch {
            finish(.failure(error))
        }
    }

    private func outcome(_ result: ContextJSON) -> Outcome {
        Outcome(reply: MCPWireReply(result: result, session: responseSession), changed: changed)
    }
}
