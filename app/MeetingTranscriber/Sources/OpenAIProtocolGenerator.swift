import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "OpenAIProtocolGenerator")

/// Generates meeting protocols via an OpenAI-compatible HTTP API (e.g. Ollama, LM Studio, llama.cpp).
struct OpenAIProtocolGenerator: ProtocolGenerating {
    let endpoint: URL
    let model: String
    let apiKey: String?
    let apiKeyPlacement: OpenAIAPIKeyPlacement
    let apiKeyHeaderName: String
    let language: String
    /// Idle timeout (`URLRequest.timeoutInterval`): max time *between* received
    /// bytes. Catches a fully-stalled connection, but does NOT bound total time —
    /// a slow-but-trickling stream resets it on every byte. See `maxTotalSeconds`.
    let timeoutSeconds: TimeInterval
    /// Wall-clock cap for a single request attempt. `timeoutSeconds` alone lets
    /// a struggling LLM that trickles tokens run for hours (each byte resets the
    /// idle timer); this deadline ends it regardless. Generous by default so a
    /// legitimately long protocol isn't cut off. Note the deadline is applied per
    /// attempt, so a call can span up to three times it (see `RequestShape`) —
    /// only reachable via an endpoint that trickles its 400 bodies.
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
    /// Sampling overrides. Nil means the key is omitted from the request body
    /// and the server's default applies. An endpoint that refuses them with a
    /// 400 naming `temperature` or `top_p` gets the request again without
    /// either; the settings themselves are left alone.
    let temperature: Double?
    let topP: Double?
    let session: URLSession

    init(
        endpoint: URL,
        model: String,
        language: String,
        apiKey: String? = nil,
        apiKeyPlacement: OpenAIAPIKeyPlacement = .bearerToken,
        apiKeyHeaderName: String = OpenAIAPIKeyPlacement.defaultHeaderName,
        timeoutSeconds: TimeInterval = 600,
        maxTotalSeconds: TimeInterval = 1800,
        maxOutputTokens: Int = 16000,
        temperature: Double? = nil,
        topP: Double? = nil,
        session: URLSession = .shared,
    ) {
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.apiKey = apiKey
        self.apiKeyPlacement = apiKeyPlacement
        self.apiKeyHeaderName = apiKeyHeaderName
        self.timeoutSeconds = timeoutSeconds
        self.maxTotalSeconds = maxTotalSeconds
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.session = session
    }

    func generate(
        transcript: String,
        title _: String,
        diarized: Bool,
        meetingStartTime: Date?,
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

        var shape = RequestShape(
            tokenLimit: .maxTokens,
            includesSampling: temperature != nil || topP != nil,
        )
        while true {
            do {
                return try await send(messages: messages, shape: shape)
            } catch let refusal as HTTPRefusal {
                guard let next = shape.fallback(status: refusal.status, after: refusal.body) else {
                    throw ProtocolError.httpError(refusal.status, refusal.shownBody)
                }
                shape = next
            }
        }
    }

    /// A non-2xx answer as `streamProtocol` read it. `body` is everything read,
    /// up to `errorBodyReadCap`, and is what the fallbacks inspect; `shownBody`
    /// is the shorter prefix that is logged and, when no fallback applies,
    /// surfaced to the user as `ProtocolError.httpError`.
    struct HTTPRefusal: Error {
        let status: Int
        let body: String
        let shownBody: String
    }

    /// How much of an error body is read, in characters with line separators
    /// excluded: enough for a pretty-printed refusal spread over many lines (as
    /// LiteLLM sends them) to arrive whole and parse.
    static let errorBodyReadCap = 4096
    /// How much of it is logged and shown to the user: the same bound as before
    /// the read cap was raised.
    static let errorBodyShownCap = 500

    /// The leading lines of an error body that are logged and shown: up to and
    /// including the line that takes the running character count past
    /// `errorBodyShownCap`. Lines are joined with newlines, like the full body,
    /// because joining without a separator fuses words across lines.
    static func shownErrorBody(_ lines: [String]) -> String {
        var kept: [String] = []
        var count = 0
        for line in lines where count <= errorBodyShownCap {
            kept.append(line)
            count += line.count
        }
        return kept.joined(separator: "\n")
    }

    /// The parts of the request body a refusal can make `generate()` change.
    /// Each fallback is one-way: the cap moves from `max_tokens` to
    /// `max_completion_tokens`, and sent sampling overrides are dropped. Every
    /// retry applies at least one of them (a single refusal may apply both), so
    /// `generate()` makes at most three attempts.
    struct RequestShape: Equatable {
        var tokenLimit: TokenLimitParameter
        /// Whether the overrides that are set go into the body. Starts true only
        /// when at least one is set, so a refusal never retries without them
        /// when nothing was sent.
        var includesSampling: Bool

        /// The shape to retry with after an HTTP `status` carrying `errorBody`,
        /// or nil when it names nothing a fallback can still change (a fallback
        /// that is already applied changes nothing), in which case the error
        /// stands. The `max_tokens` rename is only ever answered with a 400, so
        /// that fallback stays on 400; a sampling refusal may also come as the
        /// 422 that FastAPI-based servers (TGI, vLLM's validation layer) use.
        func fallback(status: Int, after errorBody: String) -> Self? {
            var next = self
            if status == 400, tokenLimit == .maxTokens, OpenAIProtocolGenerator.rejectsMaxTokens(errorBody) {
                logger.info("Endpoint rejected 'max_tokens'; retrying with 'max_completion_tokens'")
                next.tokenLimit = .maxCompletionTokens
            }
            if status == 400 || status == 422, includesSampling,
               OpenAIProtocolGenerator.rejectsSamplingParameter(errorBody) {
                logger.info("Endpoint rejected the sampling overrides; retrying without temperature/top_p for this request")
                next.includesSampling = false
            }
            return next == self ? nil : next
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

    /// True when an error body names a sampling parameter as a whole word, in
    /// any case (`top_probs` does not count): reasoning models refuse any non-default
    /// value, others the key itself or both keys together. Both overrides are
    /// dropped either way, so one retry settles all of these. Only the parts
    /// that describe the error are searched (see `errorTexts`), since some
    /// servers echo the request, overrides included, in a validation error.
    static func rejectsSamplingParameter(_ errorBody: String) -> Bool {
        let names = Set(OpenAISamplingParameter.allCases.map(\.rawValue))
        return errorTexts(in: errorBody).contains { text in
            text.split { !($0.isLetter || $0.isNumber || $0 == "_") }
                .contains { names.contains($0.lowercased()) }
        }
    }

    /// The parts of an error body that describe the error. Plain text is
    /// searched as is. JSON is searched by `errorTexts(inJSON:)`, and a body
    /// that starts like JSON but does not parse (cut off at the read cap)
    /// yields nothing, since its raw text may hold an echoed request. A string
    /// inside the JSON goes through these same rules, so an upstream body that
    /// a proxy embeds as a string is searched as JSON, not as raw text.
    private static func errorTexts(in text: String) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first
            return first == "{" || first == "[" ? [] : [text]
        }
        return errorTexts(inJSON: json)
    }

    /// Every string value inside an OpenAI-style `error` object, nested ones
    /// included (OpenRouter wraps the upstream refusal in `error.metadata.raw`);
    /// in an object without one, its `error`, `param`, `message` and `detail`
    /// strings; in an array (Gemini answers `[{"error": ...}]`), its elements.
    /// Object keys are never searched, so a request echoed as an object does
    /// not match.
    private static func errorTexts(inJSON json: Any) -> [String] {
        switch json {
        case let array as [Any]:
            return array.flatMap(errorTexts(inJSON:))

        case let object as [String: Any]:
            if let error = object["error"] as? [String: Any] {
                return stringValues(in: error).flatMap(errorTexts(in:))
            }
            return ["error", "param", "message", "detail"]
                .compactMap { object[$0] as? String }
                .flatMap(errorTexts(in:))

        default:
            return []
        }
    }

    /// All string values in a decoded JSON value, depth first.
    private static func stringValues(in value: Any) -> [String] {
        switch value {
        case let string as String: [string]
        case let object as [String: Any]: object.values.flatMap(stringValues)
        case let array as [Any]: array.flatMap(stringValues)
        default: []
        }
    }

    /// The chat-completions request body for one attempt. An unset override is
    /// omitted rather than sent as a default, and a shape without sampling
    /// leaves both overrides out.
    func requestBody(messages: [[String: Any]], shape: RequestShape) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            shape.tokenLimit.rawValue: maxOutputTokens,
        ]
        if shape.includesSampling {
            if let temperature { body[OpenAISamplingParameter.temperature.rawValue] = temperature }
            if let topP { body[OpenAISamplingParameter.topP.rawValue] = topP }
        }
        return body
    }

    private func send(
        messages: [[String: Any]], shape: RequestShape,
    ) async throws -> String {
        let bodyData = try JSONSerialization.data(
            withJSONObject: requestBody(messages: messages, shape: shape),
        )

        let requestURL = Self.apiBaseURL(from: endpoint)
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let redirectGuard = try Self.setAPIKeyHeader(
            apiKey,
            placement: apiKeyPlacement,
            headerName: apiKeyHeaderName,
            on: &request,
        )
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
                try await Self.streamProtocol(
                    session: session,
                    request: finalRequest,
                    redirectGuard: redirectGuard,
                    requestURL: requestURL,
                    model: model,
                )
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
        session: URLSession,
        request: URLRequest,
        redirectGuard: CrossOriginRedirectRefuser?,
        requestURL: URL,
        model: String,
    ) async throws -> String {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
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
            var lines: [String] = []
            var count = 0
            for try await line in bytes.lines {
                lines.append(line)
                count += line.count
                if count > errorBodyReadCap { break }
            }
            let shownBody = shownErrorBody(lines)
            logger.error(
                "openai_http_error status=\(httpResponse.statusCode, privacy: .public) endpoint=\(requestURL.absoluteString, privacy: .public) body=\(shownBody, privacy: .public)",
            )
            throw HTTPRefusal(
                status: httpResponse.statusCode,
                body: lines.joined(separator: "\n"),
                shownBody: shownBody,
            )
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

    /// Configure the key's HTTP header. Custom header names follow the HTTP
    /// token grammar and must not be one of `reservedAPIKeyHeaderNames`.
    /// Returns the task delegate that must accompany a custom header, nil when
    /// none is needed.
    private static func setAPIKeyHeader(
        _ apiKey: String?,
        placement: OpenAIAPIKeyPlacement,
        headerName: String,
        on request: inout URLRequest,
    ) throws -> CrossOriginRedirectRefuser? {
        guard let apiKey, !apiKey.isEmpty else { return nil }

        switch placement {
        case .bearerToken:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return nil

        case .customHeader:
            let name = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidAPIKeyHeaderName(name) else {
                throw ProtocolError.connectionFailed("Invalid API key header name")
            }
            request.setValue(apiKey, forHTTPHeaderField: name)
            return CrossOriginRedirectRefuser()
        }
    }

    /// Lowercased header names a custom API key header must not use. URLSession
    /// overwrites Content-Length with the real body length and silently drops
    /// Transfer-Encoding, so a key placed there never leaves the machine;
    /// Content-Type belongs to the JSON body, and the rest describe the
    /// connection itself, so sending the key in them breaks the request.
    private static let reservedAPIKeyHeaderNames: Set<String> = [
        "content-type", "content-length", "transfer-encoding", "host", "connection", "expect", "upgrade",
    ]

    /// The HTTP token characters a field name may consist of.
    private static let apiKeyHeaderNameCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
    )

    /// Return whether `name` is a valid HTTP field name that is free to carry
    /// the API key.
    static func isValidAPIKeyHeaderName(_ name: String) -> Bool {
        !name.isEmpty
            && !reservedAPIKeyHeaderNames.contains(name.lowercased())
            && name.unicodeScalars.allSatisfy(apiKeyHeaderNameCharacters.contains)
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
    static func testConnection(
        endpoint: String,
        model _: String,
        apiKey: String?,
        apiKeyPlacement: OpenAIAPIKeyPlacement = .bearerToken,
        apiKeyHeaderName: String = OpenAIAPIKeyPlacement.defaultHeaderName,
        session: URLSession = .shared,
    ) async -> Result<[String], any Error> {
        // Accept either the API base URL (.../v1) or the full chat-completions
        // URL (.../v1/chat/completions); both resolve to the same base + /models.
        guard let entered = URL(string: endpoint) else {
            return .failure(ProtocolError.connectionFailed("Invalid endpoint URL"))
        }

        let modelsURL = apiBaseURL(from: entered).appendingPathComponent("models")

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let redirectGuard: CrossOriginRedirectRefuser?
        do {
            redirectGuard = try setAPIKeyHeader(
                apiKey,
                placement: apiKeyPlacement,
                headerName: apiKeyHeaderName,
                on: &request,
            )
        } catch {
            return .failure(error)
        }

        do {
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
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

/// Refuses a redirect that leaves the origin while a custom API key header is
/// in use. URLSession drops `Authorization` when it follows a redirect but
/// replays every other header, so a custom header would follow the hop to
/// another host, port or scheme. Stripping it and following anyway would still
/// send the request body there, because a 307 or 308 replays the POST and with
/// it the transcript, in every mode. Such a hop is therefore not followed at
/// all: URLSession then returns the 3xx response itself and nothing is sent
/// there. Hops within the origin are followed unchanged. A request without a
/// custom header keeps URLSession's default redirect handling.
private final class CrossOriginRedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        // The protocol requirement declares the handler escaping; without the
        // attribute this method would no longer satisfy it and never be called.
        // swiftlint:disable:next unneeded_escaping
        completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        // An unknown source or target cannot be shown to be the same origin.
        guard let from = response.url, let to = request.url, Self.origin(from) == Self.origin(to) else {
            logger.error(
                "openai_redirect_refused status=\(response.statusCode) from=\(response.url?.host ?? "?", privacy: .public) to=\(request.url?.host ?? "?", privacy: .public)",
            )
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// Scheme and host compare case-insensitively and an omitted port is the
    /// scheme's default, so `https://h` and `https://H:443` are one origin.
    private static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)"
    }
}
