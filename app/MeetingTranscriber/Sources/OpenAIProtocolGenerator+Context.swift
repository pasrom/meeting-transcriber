import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "OpenAIProtocolGenerator")

extension OpenAIProtocolGenerator {
    var contextProvider: String {
        "openai-compatible"
    }

    var contextModel: String {
        model
    }

    var contextEndpoint: URL {
        endpoint
    }

    var contextSecret: String? {
        apiKey
    }

    func planContext(
        instructions: String, data: String, seconds: TimeInterval,
        authorize: @escaping @MainActor @Sendable () -> Bool,
    ) async throws -> String {
        try await complete(
            [["role": "system", "content": instructions], ["role": "user", "content": data]],
            context: ContextRequest(
                deadline: ContinuousClock.now + .seconds(seconds), outputBytes: ContextLimits.plannerReply,
                outputTokens: ContextLimits.plannerOutputTokens,
                authorize: authorize,
            ),
        )
    }

    func generateWithContext(
        transcript: String, diarized: Bool, meetingStartTime: Date?, evidence: String,
        authorize: @escaping @MainActor @Sendable () -> Bool,
    ) async throws -> String {
        let systemPrompt = ContextEnrichment.notesInstructions + "\n\n" + ProtocolGenerator.buildSystemPrompt(
            diarized: diarized, language: language, meetingStartTime: meetingStartTime,
        )
        let quotedTranscript = try ContextJSON.encodedText(transcript)
        let data = "{\"transcript\":" + quotedTranscript
            + ",\"external_evidence\":" + evidence + "}"
        guard systemPrompt.utf8.count + data.utf8.count <= ContextLimits.notesInput else { throw ContextFailure.limit }
        return try await complete(
            [["role": "system", "content": systemPrompt], ["role": "user", "content": data]],
            context: ContextRequest(
                deadline: nil, outputBytes: ContextLimits.notesReply, outputTokens: nil, authorize: authorize,
            ),
        )
    }

    struct ContextRequest: Sendable {
        let deadline: ContinuousClock.Instant?
        let outputBytes: Int
        let outputTokens: Int?
        let authorize: @MainActor @Sendable () -> Bool
    }

    static func contextJSONText(_ data: Data, cap: Int) throws -> String {
        let body = try JSONDecoder().decode(ContextJSON.self, from: data)
        let choice = body["choices"]?.array?.first
        guard choice?["finish_reason"] != .string("length") else { throw ProtocolError.protocolTruncated }
        guard let text = choice?["message"]?["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw ProtocolError.emptyProtocol }
        guard text.utf8.count <= cap else { throw ProtocolError.protocolTruncated }
        return text
    }

    static func readCompletion(_ bytes: URLSession.AsyncBytes, mimeType: String?, model: String, cap: Int?) async throws -> String {
        if let cap, mimeType == "application/json" {
            var data = Data()
            for try await byte in bytes {
                guard data.count < cap + ContextLimits.responseEnvelope else { throw ProtocolError.protocolTruncated }
                data.append(byte)
            }
            return try contextJSONText(data, cap: cap)
        }

        var parts: [String] = []
        var finishReason: String?
        var outputBytes = 0
        for try await line in bytes.lines {
            guard let chunk = parseSSELine(line) else { continue }
            if let content = chunk.content {
                if let cap {
                    outputBytes += content.utf8.count
                    guard outputBytes <= cap else { throw ProtocolError.protocolTruncated }
                }
                parts.append(content)
            }
            if let reason = chunk.finishReason { finishReason = reason }
        }

        // "length" = the model hit max_tokens or the context window, so the
        // protocol is cut off mid-way. Surface it rather than save a partial as
        // if it finished cleanly (only "stop" is a real completion).
        guard finishReason != "length" else {
            if cap == nil {
                logger.error("openai_truncated finish_reason=length model=\(model, privacy: .public)")
            }
            throw ProtocolError.protocolTruncated
        }

        let result = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw ProtocolError.emptyProtocol
        }

        return result
    }
}
