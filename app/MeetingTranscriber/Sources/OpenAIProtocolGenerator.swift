import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "OpenAIProtocolGenerator")

/// Generates meeting protocols via an OpenAI-compatible HTTP API (e.g. Ollama, LM Studio, llama.cpp).
struct OpenAIProtocolGenerator: ProtocolGenerating {
    let endpoint: URL
    let model: String
    let apiKey: String?
    let language: String
    let timeoutSeconds: TimeInterval
    let session: URLSession

    init(
        endpoint: URL,
        model: String,
        language: String,
        apiKey: String? = nil,
        timeoutSeconds: TimeInterval = 600,
        session: URLSession = .shared,
    ) {
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
        self.session = session
    }

    func generate(transcript: String, title _: String, diarized: Bool) async throws -> String {
        let systemPrompt = ProtocolGenerator.buildSystemPrompt(diarized: diarized, language: language)

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": transcript],
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
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

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            logger.error(
                "openai_connection_failed endpoint=\(requestURL.absoluteString, privacy: .public) model=\(self.model, privacy: .public) error=\(error.localizedDescription, privacy: .public)",
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
        for try await line in bytes.lines {
            if let content = parseSSELine(line) {
                parts.append(content)
            }
        }

        let result = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw ProtocolError.emptyProtocol
        }

        return result
    }

    /// Parse a single SSE line and extract the content delta.
    /// Returns `nil` for non-content lines (e.g. `data: [DONE]`, empty lines, comments).
    static func parseSSELine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard trimmed.hasPrefix("data: ") else { return nil }
        let payload = String(trimmed.dropFirst(6))

        if payload == "[DONE]" { return nil }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }

        return content
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

// Private instance helper that delegates to the static method
private extension OpenAIProtocolGenerator {
    func parseSSELine(_ line: String) -> String? {
        Self.parseSSELine(line)
    }
}
