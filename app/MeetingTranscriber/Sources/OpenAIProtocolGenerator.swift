import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "OpenAIProtocolGenerator")

/// Generates meeting protocols via an OpenAI-compatible HTTP API (e.g. Ollama, LM Studio, llama.cpp).
struct OpenAIProtocolGenerator: ProtocolGenerating {
    let endpoint: URL
    let model: String
    let apiKey: String?
    let language: String
    /// Idle timeout (`URLRequest.timeoutInterval`): max time *between* received
    /// bytes. Catches a fully-stalled connection, but does NOT bound total time —
    /// a slow-but-trickling stream resets it on every byte. See `maxTotalSeconds`.
    let timeoutSeconds: TimeInterval
    /// Wall-clock cap for a single request attempt. `timeoutSeconds` alone lets
    /// a struggling LLM that trickles tokens run for hours (each byte resets the
    /// idle timer); this deadline ends it regardless. Generous by default so a
    /// legitimately long protocol isn't cut off. Note the deadline is applied per
    /// attempt, so the `max_completion_tokens` fallback in `generate()` can span
    /// up to twice it — only reachable via an endpoint that trickles a 400 body.
    let maxTotalSeconds: TimeInterval
    /// Output-token cap sent as `max_tokens`, or `max_completion_tokens` when the
    /// endpoint rejects the former. Bounds a runaway/verbose
    /// generation (the 131k-context case that ground for ~2h) by length rather
    /// than time. Generous — a meeting protocol is well under this — and a hit
    /// is surfaced as `protocolTruncated`, never silently presented as complete.
    ///
    /// The two names are not interchangeable: `max_completion_tokens` bounds
    /// visible output tokens *plus* reasoning tokens, and reasoning tokens never
    /// arrive as content deltas. A long transcript can therefore end the stream on
    /// `finish_reason: length` with little or no content, surfaced here as
    /// `protocolTruncated`. The old name never had to account for that, since the
    /// models that accept it emit no reasoning tokens.
    let maxOutputTokens: Int
    let session: URLSession

    init(
        endpoint: URL,
        model: String,
        language: String,
        apiKey: String? = nil,
        timeoutSeconds: TimeInterval = 600,
        maxTotalSeconds: TimeInterval = 1800,
        maxOutputTokens: Int = 16000,
        session: URLSession = .shared,
    ) {
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
        self.maxTotalSeconds = maxTotalSeconds
        self.maxOutputTokens = maxOutputTokens
        self.session = session
    }

    func generate(
        transcript: String,
        title _: String,
        diarized: Bool,
        meetingStartTime: Date = Date(),
    ) async throws -> String {
        let systemPrompt = ProtocolGenerator.buildSystemPrompt(
            diarized: diarized,
            language: language,
            meetingStartTime: meetingStartTime,
        )

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": transcript],
        ]

        do {
            return try await send(messages: messages, tokenLimit: .maxTokens)
        } catch let ProtocolError.httpError(status, body)
            where status == 400 && Self.rejectsMaxTokens(body) {
            logger.info("Endpoint rejected 'max_tokens'; retrying with 'max_completion_tokens'")
            return try await send(messages: messages, tokenLimit: .maxCompletionTokens)
        }
    }

    /// Name of the output-token cap parameter in the request body.
    ///
    /// OpenAI renamed `max_tokens` to `max_completion_tokens`; current models
    /// (GPT-5 family and newer) reject the old name with HTTP 400, while local
    /// servers such as LM Studio and Ollama only understand the old one. So the
    /// old name is sent first and the new one used only on an explicit refusal.
    enum TokenLimitParameter: String {
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }

    /// True when a 400 body is the API specifically refusing `max_tokens` and
    /// naming `max_completion_tokens` as the replacement. Both names must appear
    /// so unrelated 400s (bad model, bad key, malformed request) don't retry.
    static func rejectsMaxTokens(_ errorBody: String) -> Bool {
        errorBody.contains(TokenLimitParameter.maxCompletionTokens.rawValue)
            && errorBody.contains(TokenLimitParameter.maxTokens.rawValue)
    }

    private func send(
        messages: [[String: Any]], tokenLimit: TokenLimitParameter,
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            tokenLimit.rawValue: maxOutputTokens,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let requestURL = Self.apiBaseURL(from: endpoint)
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData
        request.timeoutInterval = timeoutSeconds

        logger.info("Generating protocol via OpenAI-compatible API (\(model))...")

        // Race the streaming consume against a hard total deadline: the idle
        // timeout above can't end a stream that keeps trickling bytes, so a
        // struggling endpoint would otherwise hang the pipeline indefinitely.
        // Capture only immutable Sendable locals so the task closure is safe.
        let session = self.session
        let model = self.model
        let deadline = maxTotalSeconds
        let finalRequest = request
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.streamProtocol(session: session, request: finalRequest, requestURL: requestURL, model: model)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw ProtocolError.generationTimedOut(Int(deadline))
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ProtocolError.connectionFailed("No response")
            }
            return result
        }
    }

    /// Open the streaming request and accumulate the SSE content deltas. Static
    /// so the deadline race captures only Sendable locals, not `self`.
    private static func streamProtocol(
        session: URLSession, request: URLRequest, requestURL: URL, model: String,
    ) async throws -> String {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            logger.error(
                "openai_connection_failed endpoint=\(requestURL.absoluteString, privacy: .public) model=\(model, privacy: .public) error=\(error.localizedDescription, privacy: .public)",
            )
            throw ProtocolError.connectionFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("openai_invalid_response endpoint=\(requestURL.absoluteString, privacy: .public)")
            throw ProtocolError.connectionFailed("Invalid response")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            // Try to read error body
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            logger.error(
                "openai_http_error status=\(httpResponse.statusCode, privacy: .public) endpoint=\(requestURL.absoluteString, privacy: .public) body=\(errorBody, privacy: .public)",
            )
            throw ProtocolError.httpError(httpResponse.statusCode, errorBody)
        }

        var parts: [String] = []
        var finishReason: String?
        for try await line in bytes.lines {
            guard let chunk = parseSSELine(line) else { continue }
            if let content = chunk.content { parts.append(content) }
            if let reason = chunk.finishReason { finishReason = reason }
        }

        // "length" = the model hit max_tokens or the context window, so the
        // protocol is cut off mid-way. Surface it rather than save a partial as
        // if it finished cleanly (only "stop" is a real completion).
        guard finishReason != "length" else {
            logger.error("openai_truncated finish_reason=length model=\(model, privacy: .public)")
            throw ProtocolError.protocolTruncated
        }

        let result = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw ProtocolError.emptyProtocol
        }

        return result
    }

    /// One parsed SSE chunk: the content delta (if any) and the finish reason,
    /// which is set only on the terminating chunk ("stop" = clean completion,
    /// "length" = truncated at the output/context limit).
    struct SSEChunk: Equatable {
        let content: String?
        let finishReason: String?
    }

    /// Parse a single SSE line into its content delta + finish reason. Returns
    /// `nil` for non-data lines (`data: [DONE]`, comments, empty, unparseable)
    /// and for chunks carrying neither a content delta nor a finish reason.
    static func parseSSELine(_ line: String) -> SSEChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard trimmed.hasPrefix("data: ") else { return nil }
        let payload = String(trimmed.dropFirst(6))

        if payload == "[DONE]" { return nil }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first
        else { return nil }

        let content = (first["delta"] as? [String: Any])?["content"] as? String
        let finishReason = first["finish_reason"] as? String
        if content == nil, finishReason == nil { return nil }
        return SSEChunk(content: content, finishReason: finishReason)
    }

    /// Normalize a user-entered endpoint to the OpenAI API *base* URL (e.g.
    /// `http://host/v1`), from which the concrete `/chat/completions` and
    /// `/models` paths are derived.
    ///
    /// Accepts both conventions so no existing configuration breaks:
    ///   - base URL:          `http://host/v1`                  → `http://host/v1`
    ///   - full endpoint URL: `http://host/v1/chat/completions` → `http://host/v1`
    ///
    /// The OpenAI ecosystem (and LM Studio's own UI) presents the base URL,
    /// while this app historically shipped the full chat-completions URL as its
    /// default — collapsing both to the same base means either works.
    static func apiBaseURL(from endpoint: URL) -> URL {
        guard endpoint.lastPathComponent == "completions" else { return endpoint }
        let chat = endpoint.deletingLastPathComponent()
        guard chat.lastPathComponent == "chat" else { return endpoint }
        return chat.deletingLastPathComponent()
    }

    /// Test connection to the API by querying available models.
    /// Returns model names on success.
    static func testConnection(endpoint: String, model _: String, apiKey: String?, session: URLSession = .shared) async -> Result<[String], any Error> {
        // Accept either the API base URL (.../v1) or the full chat-completions
        // URL (.../v1/chat/completions); both resolve to the same base + /models.
        guard let entered = URL(string: endpoint) else {
            return .failure(ProtocolError.connectionFailed("Invalid endpoint URL"))
        }

        let modelsURL = apiBaseURL(from: entered).appendingPathComponent("models")

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode)
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failure(ProtocolError.httpError(code, "Failed to fetch models"))
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["data"] as? [[String: Any]]
            else {
                return .success([])
            }

            let names = modelList.compactMap { $0["id"] as? String }.sorted()
            return .success(names)
        } catch {
            return .failure(ProtocolError.connectionFailed(error.localizedDescription))
        }
    }
}
