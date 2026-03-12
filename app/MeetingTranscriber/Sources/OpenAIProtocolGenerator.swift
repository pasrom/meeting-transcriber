import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "OpenAIProtocolGenerator")

/// Generates meeting protocols via an OpenAI-compatible HTTP API (e.g. Ollama, LM Studio, llama.cpp).
struct OpenAIProtocolGenerator: ProtocolGenerating {
    let endpoint: URL
    let model: String
    let apiKey: String?
    let timeoutSeconds: TimeInterval

    init(endpoint: URL, model: String, apiKey: String? = nil, timeoutSeconds: TimeInterval = 600) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
    }

    func generate(transcript: String, title: String, diarized: Bool) async throws -> String {
        var systemPrompt = ProtocolGenerator.protocolPrompt
        if diarized {
            systemPrompt += ProtocolGenerator.diarizationNote
        }

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

        var request = URLRequest(url: endpoint)
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
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw ProtocolError.connectionFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProtocolError.connectionFailed("Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to read error body
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
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

    /// Test connection to the API by querying available models.
    /// Returns model names on success.
    static func testConnection(endpoint: String, model: String, apiKey: String?) async -> Result<[String], Error> {
        // Derive models endpoint from chat completions endpoint
        guard let chatURL = URL(string: endpoint) else {
            return .failure(ProtocolError.connectionFailed("Invalid endpoint URL"))
        }

        // Navigate from .../v1/chat/completions to .../v1/models
        let baseURL = chatURL.deletingLastPathComponent().deletingLastPathComponent()
        let modelsURL = baseURL.appendingPathComponent("models")

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
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
